"""오디오 → Whisper 받아쓰기 + 구간별 음량(dB)."""
import subprocess
import wave
from pathlib import Path

SILENCE_DB = -52.0  # 이보다 조용한 구간의 전사는 Whisper 환각으로 보고 버림
HALLUCINATIONS = ("한글자막", "자막 by", "시청해 주셔서", "구독과 좋아요", "MBC 뉴스")


def fmt_ts(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def to_mono16k(inputs: list[Path], out: Path):
    """여러 파일은 이어 붙여 16kHz 모노 wav 하나로 만든다."""
    args = sum((["-i", str(p)] for p in inputs), [])
    if len(inputs) > 1:
        streams = "".join(f"[{i}:a]" for i in range(len(inputs)))
        args += ["-filter_complex", f"{streams}concat=n={len(inputs)}:v=0:a=1"]
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *args, "-ac", "1", "-ar", "16000", str(out)],
                   check=True)


def transcribe(inputs: list[Path], workdir: Path, model: str, language: str) -> str:
    """'[시각] 음량dB | 텍스트' 줄들을 반환."""
    import mlx_whisper
    import numpy as np

    mono = workdir / "audio16k.wav"
    to_mono16k(inputs, mono)
    result = mlx_whisper.transcribe(str(mono), path_or_hf_repo=model,
                                    language=None if language == "auto" else language,
                                    condition_on_previous_text=False)
    with wave.open(str(mono)) as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

    lines = []
    for seg in result["segments"]:
        text = seg["text"].strip()
        x = audio[int(seg["start"] * 16000):int(seg["end"] * 16000)]
        if not text or len(x) < 800:
            continue
        frames = x[:len(x) // 800 * 800].reshape(-1, 800)  # 50ms 프레임
        db = 20 * np.log10(np.percentile(np.sqrt((frames ** 2).mean(1)), 90) + 1e-9)
        if db < SILENCE_DB or any(h in text for h in HALLUCINATIONS):
            continue
        lines.append(f"[{fmt_ts(seg['start'])}] {db:6.1f}dB | {text}")
    return "\n".join(lines)


def label_by_loudness(raw: str) -> str:
    """LLM 없이 쓸 때: 음량 중앙값 기준으로 A/B를 나눈 단순 스크립트."""
    import re
    import statistics

    rows = [(m.group(1), float(m.group(2)), m.group(3))
            for m in re.finditer(r"^\[(.+?)\]\s+(-?[\d.]+)dB \| (.*)$", raw, re.M)]
    if not rows:
        return ""
    cut = statistics.median(db for _, db, _ in rows) - 4
    out, prev = [], None
    for ts, db, text in rows:
        who = "A" if db >= cut else "B"
        if who == prev:
            out[-1] += " " + text
        else:
            out.append(f"**[{ts}] {who}:** {text}")
        prev = who
    return "\n\n".join(out)
