"""화자 분리·교정·요약. 백엔드: Claude Code CLI 또는 Anthropic API."""
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .config import Config

CHUNK_SEC = 10 * 60  # 대본을 10분 조각으로 나눠 동시에 교정(조각이 작을수록 빨리 끝남)

TRANSCRIPT_PROMPT = """아래는 마이크로 녹음한 대화(DJI 무선 마이크·Mac 마이크·온라인 회의 등)를 Whisper로 받아쓴 원문이다.
각 줄 형식: [시각] 음량dB [@화자] | 텍스트

할 일: 화자를 분리하고 읽기 좋게 정리한 대화 스크립트 본문을 Markdown으로 작성하라.
- 줄에 `@이름`이 있으면 채널(마이크)로 확정된 화자다. 그 이름을 그대로 화자로 쓴다.
  `@이름(?)`은 두 채널 소리가 비슷했던 구간이니 맥락으로 보정하고, 애매하면 "이름 (?)"로 표시.
- `@`가 없으면: 마이크 착용자(A)는 음량이 크고, 상대방(B, 필요하면 C…)은 작다. 이 녹음의 음량 분포를 보고 기준을 잡아라.
  음량을 1차 기준으로 쓰되, 질문-대답 흐름·말투·내용 맥락으로 보정하라. 애매하면 "A (?)" 처럼 표시.
- 같은 화자의 연속 발화는 한 문단으로 합치고 문단 앞에 시작 시각을 붙인다: **[mm:ss] A:** ...
- 명백한 음성인식 오류는 맥락상 올바른 단어로 고치고 뒤에 [원문: …] 을 남긴다. 추측이 어려운 부분은 [불명확].
- 말더듬·반복은 적당히 정리하되 내용을 지어내거나 빼지 말 것. 의미 없는 환각 문장은 삭제.
- 긴 무음 구간이 있으면 *(mm:ss~mm:ss 무음)* 으로 표시.
출력: 스크립트 본문 Markdown만(제목·설명·코드블록 없이).

원문:
{raw}
"""

SUMMARY_PROMPT = """아래는 대화 스크립트다(화자 이름은 스크립트에 표시된 대로. A/B면 A=마이크 착용자, B=상대방). 회의록 요약을 Markdown으로 작성하라.

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


# 공급자별 기본 모델: (요약용, 대본 정리용). 앱의 선택지와 `config set`의 기본값으로 쓴다.
PROVIDERS = {
    "claude-cli":    {"title": "Claude Code (구독)",     "models": ("claude-opus-5-5", "claude-sonnet-5")},
    "codex-cli":     {"title": "OpenAI Codex (구독)",    "models": ("", "")},  # 빈 값 = codex 기본 모델
    "anthropic-api": {"title": "Anthropic API",          "models": ("claude-opus-5-5", "claude-sonnet-5")},
    "openai-api":    {"title": "OpenAI API",             "models": ("gpt-5", "gpt-5-mini")},
    "gemini-api":    {"title": "Google Gemini API",      "models": ("gemini-2.5-pro", "gemini-2.5-flash")},
    "baryon":        {"title": "Baryon AI",              "models": ("claude-sonnet-5", "claude-sonnet-5")},
    "none":          {"title": "사용 안 함",              "models": ("", "")},
}


def detect_backend() -> str:
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "anthropic-api"
    if claude_cli_path():
        return "claude-cli"
    if codex_cli_path():
        return "codex-cli"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai-api"
    if os.environ.get("GEMINI_API_KEY"):
        return "gemini-api"
    return "none"


def claude_cli_path():
    return shutil.which("claude")


def codex_cli_path():
    """codex가 여러 곳에 설치돼 있으면(예: 오래된 Homebrew판 + npm판) 가장 새 버전을 쓴다."""
    found = []
    for d in os.environ.get("PATH", "").split(os.pathsep):
        exe = Path(d) / "codex"
        if exe.is_file() and os.access(exe, os.X_OK) and str(exe) not in [f[1] for f in found]:
            out = subprocess.run([str(exe), "--version"], capture_output=True, text=True, timeout=20)
            m = re.search(r"(\d+)\.(\d+)\.(\d+)", out.stdout)
            found.append((tuple(map(int, m.groups())) if m else (0, 0, 0), str(exe)))
    return max(found)[1] if found else None


def _run_cli(cmd: list[str], prompt: str, name: str) -> subprocess.CompletedProcess:
    import getpass
    env = {**os.environ, "USER": os.environ.get("USER") or getpass.getuser()}  # 로그인 확인에 필요
    out = subprocess.run(cmd, input=prompt, capture_output=True, text=True, env=env,
                         cwd=tempfile.gettempdir(), timeout=1800)
    if out.returncode != 0:
        raise RuntimeError(f"{name} 실패: {(out.stderr or out.stdout)[-400:]}")
    return out


def _post_json(url: str, body: dict, headers: dict) -> dict:
    import json
    import urllib.error
    import urllib.request
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None


def ask(cfg: Config, prompt: str, model: str | None = None) -> str:
    model = model or cfg.llm_model
    backend = cfg.llm_backend

    if backend == "claude-cli":
        cli = claude_cli_path()
        if not cli:
            raise RuntimeError("claude CLI를 찾을 수 없습니다")
        cmd = [cli, "-p", "--output-format", "text", "--tools", "", "--no-session-persistence"]
        if model:
            cmd += ["--model", model]
        text = _run_cli(cmd, prompt, "claude CLI").stdout

    elif backend == "codex-cli":
        cli = codex_cli_path()
        if not cli:
            raise RuntimeError("codex CLI를 찾을 수 없습니다")
        with tempfile.NamedTemporaryFile("r", suffix=".txt", delete=False) as f:
            last = f.name
        cmd = [cli, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
               "--output-last-message", last]
        if model:
            cmd += ["-m", model]
        _run_cli(cmd + ["-"], prompt, "codex CLI")
        text = Path(last).read_text()
        Path(last).unlink(missing_ok=True)

    elif backend in ("anthropic-api", "baryon"):
        # Baryon AI는 Anthropic 호환 Messages API (x-api-key)
        import anthropic
        if backend == "baryon":
            if not cfg.baryon_api_url:
                raise RuntimeError("Baryon AI 주소(baryon_api_url)가 설정되지 않았습니다")
            client = anthropic.Anthropic(api_key=cfg.baryon_api_key, base_url=cfg.baryon_api_url.rstrip("/"))
        else:
            client = anthropic.Anthropic(api_key=cfg.anthropic_api_key or os.environ.get("ANTHROPIC_API_KEY"))
        with client.messages.stream(model=model, max_tokens=32000,
                                    messages=[{"role": "user", "content": prompt}]) as s:
            msg = s.get_final_message()
        text = "".join(b.text for b in msg.content if b.type == "text")

    elif backend == "openai-api":
        key = cfg.openai_api_key or os.environ.get("OPENAI_API_KEY")
        data = _post_json("https://api.openai.com/v1/chat/completions",
                          {"model": model, "messages": [{"role": "user", "content": prompt}]},
                          {"authorization": f"Bearer {key}"})
        text = data["choices"][0]["message"]["content"]

    elif backend == "gemini-api":
        key = cfg.gemini_api_key or os.environ.get("GEMINI_API_KEY")
        data = _post_json(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
                          {"contents": [{"role": "user", "parts": [{"text": prompt}]}]},
                          {"x-goog-api-key": key})
        text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])

    else:
        raise RuntimeError("AI가 설정되지 않았습니다")
    if not text.strip():
        raise RuntimeError(f"{backend}: 빈 응답")
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


def make_transcript(cfg: Config, raw: str, log=print, cache_dir: Path | None = None) -> str:
    """조각을 동시에 교정한다. 순서는 원래대로 이어 붙인다.

    cache_dir을 주면 끝난 조각을 저장해 두고, 중단 후 다시 실행할 때 그 조각은 건너뛴다.
    """
    import hashlib
    from concurrent.futures import ThreadPoolExecutor, as_completed

    chunks = list(_chunks(raw))
    model = cfg.llm_fast_model or cfg.llm_model
    results: list[str] = [""] * len(chunks)

    def cache_path(i: int, text: str) -> Path | None:
        if not cache_dir:
            return None
        digest = hashlib.sha1((model + text).encode()).hexdigest()[:10]
        return cache_dir / f"{i:03d}-{digest}.md"

    todo = []
    for i, c in enumerate(chunks):
        p = cache_path(i, c)
        if p and p.exists():
            results[i] = p.read_text().strip()
        else:
            todo.append(i)
    done = len(chunks) - len(todo)
    workers = min(cfg.llm_parallel, 2) if cfg.low_power else cfg.llm_parallel
    log(f"AI 정리 [{done}/{len(chunks)}] ({model or '기본 모델'}, 동시 {workers}개)")
    if cache_dir:
        cache_dir.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = {pool.submit(ask, cfg, TRANSCRIPT_PROMPT.format(raw=chunks[i]), model): i for i in todo}
        for f in as_completed(futures):
            i = futures[f]
            results[i] = f.result().strip()
            if (p := cache_path(i, chunks[i])):
                p.write_text(results[i] + "\n")
            done += 1
            log(f"AI 정리 [{done}/{len(chunks)}]")
    return "\n\n".join(results) + "\n"


def make_summary(cfg: Config, title: str, transcript: str) -> str:
    return ask(cfg, SUMMARY_PROMPT.format(title=title, transcript=transcript))
