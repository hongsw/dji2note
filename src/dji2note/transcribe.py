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


def channel_count(path: Path) -> int:
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    import re
    m = re.search(r"Audio:.*?, \d+ Hz, (mono|stereo|(\d+) channels|[\w.()]+)", out)
    if not m:
        return 1
    if m.group(1) == "mono":
        return 1
    if m.group(1) == "stereo":
        return 2
    return int(m.group(2)) if m.group(2) else 2


def merge_channels(inputs: list[Path], out: Path):
    """파일 여러 개를 채널로 합친다(온라인 회의: 내 마이크=1채널, Mac 소리=2채널). 짧은 쪽은 무음으로 채움."""
    n = len(inputs)
    args = sum((["-i", str(p)] for p in inputs), [])
    chains = "".join(f"[{i}:a]aresample=48000,aformat=channel_layouts=mono,apad[a{i}];" for i in range(n))
    merge = "".join(f"[a{i}]" for i in range(n)) + f"amerge=inputs={n}[out]"
    longest = max(_duration(p) for p in inputs)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *args, "-filter_complex", chains + merge,
                    "-map", "[out]", "-t", f"{longest:.3f}", "-c:a", "pcm_s16le", str(out)], check=True)


def _duration(path: Path) -> float:
    import re
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", out)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0


def transcribe(inputs: list[Path], workdir: Path, model: str, language: str,
               speakers: list[str] | None = None) -> str:
    """'[시각] 음량dB | 텍스트' 줄들을 반환.

    2채널 이상 녹음(DJI 수신기 분리 채널, 온라인 회의)이면 구간마다 가장 큰 채널로 화자를 정해
    '[시각] 음량dB @화자 | 텍스트' 로 표시한다. speakers는 채널 순서대로의 이름.
    """
    import mlx_whisper
    import numpy as np

    mono = workdir / "audio16k.wav"
    to_mono16k(inputs, mono)
    nch = channel_count(inputs[0]) if len(inputs) == 1 else 1
    chans = None
    if nch >= 2:
        multi = workdir / "multi16k.wav"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(inputs[0]), "-ar", "16000",
                        "-c:a", "pcm_s16le", str(multi)], check=True)
        with wave.open(str(multi)) as w:
            chans = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32).reshape(-1, nch).T / 32768
        names = (speakers or []) + [chr(ord("A") + i) for i in range(len(speakers or []), nch)]
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
        tag = ""
        if chans is not None:
            a, b = int(seg["start"] * 16000), int(seg["end"] * 16000)
            levels = [20 * np.log10(np.sqrt((c[a:b] ** 2).mean()) + 1e-9) for c in chans]
            order = np.argsort(levels)[::-1]
            # 두 채널이 비슷하면(겹쳐 말함·반향) 불확실 표시
            sure = levels[order[0]] - levels[order[1]] >= 3
            tag = f" @{names[order[0]]}{'' if sure else '(?)'}"
        lines.append(f"[{fmt_ts(seg['start'])}] {db:6.1f}dB{tag} | {text}")
    return "\n".join(lines)


def label_by_loudness(raw: str) -> str:
    """LLM 없이 쓸 때: 음량 중앙값 기준으로 A/B를 나눈 단순 스크립트."""
    import re
    import statistics

    rows = [(m.group(1), float(m.group(2)), m.group(3), m.group(4))
            for m in re.finditer(r"^\[(.+?)\]\s+(-?[\d.]+)dB(?: @(\S+))? \| (.*)$", raw, re.M)]
    if not rows:
        return ""
    cut = statistics.median(db for _, db, _, _ in rows) - 4
    out, prev = [], None
    for ts, db, tag, text in rows:
        # 채널로 정해진 화자가 있으면 그대로, 없으면 음량 기준
        who = tag if tag else ("A" if db >= cut else "B")
        if who == prev:
            out[-1] += " " + text
        else:
            out.append(f"**[{ts}] {who}:** {text}")
        prev = who
    return "\n\n".join(out)
