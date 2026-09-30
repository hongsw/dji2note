"""화자 분리·교정·요약. 백엔드: Claude Code CLI 또는 Anthropic API."""
import os
import re
import shutil
import subprocess
import tempfile

from .config import Config

CHUNK_SEC = 10 * 60  # 대본을 10분 조각으로 나눠 동시에 교정(조각이 작을수록 빨리 끝남)

TRANSCRIPT_PROMPT = """아래는 무선 마이크(송신기 1개, 옷에 부착)로 녹음한 대화를 Whisper로 받아쓴 원문이다.
각 줄 형식: [시각] 음량dB | 텍스트

할 일: 화자를 분리하고 읽기 좋게 정리한 대화 스크립트 본문을 Markdown으로 작성하라.
- 화자 판정: 마이크 착용자(A)는 음량이 크고, 상대방(B, 필요하면 C…)은 작다. 이 녹음의 음량 분포를 보고 기준을 잡아라.
  음량을 1차 기준으로 쓰되, 질문-대답 흐름·말투·내용 맥락으로 보정하라. 애매하면 "A (?)" 처럼 표시.
- 같은 화자의 연속 발화는 한 문단으로 합치고 문단 앞에 시작 시각을 붙인다: **[mm:ss] A:** ...
- 명백한 음성인식 오류는 맥락상 올바른 단어로 고치고 뒤에 [원문: …] 을 남긴다. 추측이 어려운 부분은 [불명확].
- 말더듬·반복은 적당히 정리하되 내용을 지어내거나 빼지 말 것. 의미 없는 환각 문장은 삭제.
- 긴 무음 구간이 있으면 *(mm:ss~mm:ss 무음)* 으로 표시.
출력: 스크립트 본문 Markdown만(제목·설명·코드블록 없이).

원문:
{raw}
"""

SUMMARY_PROMPT = """아래는 대화 스크립트다(A=마이크 착용자, B=상대방). 회의록 요약을 Markdown으로 작성하라.

형식:
# 대화 요약 — {title}

**참석:** (A/B가 각각 어떤 역할로 보이는지 한 줄)
**주제:** (한 줄)

## 한 줄 요약
## 주요 내용
(주제별 ### 소제목 + 불릿. 수치·고유명사·제품명·도메인은 정확히)
## 결정 사항
## 할 일 (Action Items)
| 담당 | 할 일 | 기한 |
|---|---|---|
## 참고
(화자 추정의 한계, 사실 확인이 필요한 점. 없으면 생략)

대화에 없는 내용은 지어내지 말 것. 잡담뿐이면 짧게 그렇다고만 쓸 것.
스크립트와 같은 언어로 작성. 출력: Markdown만(코드블록으로 감싸지 말 것).

스크립트:
{transcript}
"""


def detect_backend() -> str:
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "anthropic-api"
    if claude_cli_path():
        return "claude-cli"
    return "none"


def claude_cli_path():
    return shutil.which("claude")


def ask(cfg: Config, prompt: str, model: str | None = None) -> str:
    model = model or cfg.llm_model
    if cfg.llm_backend == "claude-cli":
        cli = claude_cli_path()
        if not cli:
            raise RuntimeError("claude CLI를 찾을 수 없습니다")
        cmd = [cli, "-p", "--output-format", "text", "--tools", "", "--no-session-persistence"]
        if model:
            cmd += ["--model", model]
        import getpass
        env = {**os.environ, "USER": os.environ.get("USER") or getpass.getuser()}  # 로그인 확인에 필요
        out = subprocess.run(cmd, input=prompt, capture_output=True, text=True, env=env,
                             cwd=tempfile.gettempdir(), timeout=1800)
        if out.returncode != 0 or not out.stdout.strip():
            raise RuntimeError(f"claude CLI 실패: {(out.stderr or out.stdout)[-400:]}")
        text = out.stdout
    elif cfg.llm_backend == "anthropic-api":
        import anthropic
        client = anthropic.Anthropic(api_key=cfg.anthropic_api_key or os.environ.get("ANTHROPIC_API_KEY"))
        with client.messages.stream(model=model, max_tokens=32000,
                                    messages=[{"role": "user", "content": prompt}]) as s:
            msg = s.get_final_message()
        text = "".join(b.text for b in msg.content if b.type == "text")
    else:
        raise RuntimeError("LLM 백엔드가 설정되지 않았습니다")
    return _strip_fence(text).strip() + "\n"


def _strip_fence(text: str) -> str:
    m = re.fullmatch(r"\s*```(?:markdown|md)?\n(.*)\n```\s*", text, re.S)
    return m.group(1) if m else text


def _chunks(raw: str):
    """시각 기준으로 CHUNK_SEC 단위로 자른다."""
    chunk, start = [], 0
    for line in raw.splitlines():
        m = re.match(r"\[(?:(\d+):)?(\d+):(\d+)\]", line)
        t = (int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3))) if m else 0
        if chunk and t - start >= CHUNK_SEC:
            yield "\n".join(chunk)
            chunk, start = [], t
        if not chunk:
            start = t
        chunk.append(line)
    if chunk:
        yield "\n".join(chunk)


def make_transcript(cfg: Config, raw: str, log=print) -> str:
    """조각을 동시에 교정한다. 순서는 원래대로 이어 붙인다."""
    from concurrent.futures import ThreadPoolExecutor, as_completed

    chunks = list(_chunks(raw))
    model = cfg.llm_fast_model or cfg.llm_model
    results: list[str] = [""] * len(chunks)
    done = 0
    log(f"AI 정리 [0/{len(chunks)}] ({model}, 동시 {cfg.llm_parallel}개)")
    with ThreadPoolExecutor(max_workers=max(1, cfg.llm_parallel)) as pool:
        futures = {pool.submit(ask, cfg, TRANSCRIPT_PROMPT.format(raw=c), model): i for i, c in enumerate(chunks)}
        for f in as_completed(futures):
            results[futures[f]] = f.result().strip()
            done += 1
            log(f"AI 정리 [{done}/{len(chunks)}]")
    return "\n\n".join(results) + "\n"


def make_summary(cfg: Config, title: str, transcript: str) -> str:
    return ask(cfg, SUMMARY_PROMPT.format(title=title, transcript=transcript))
