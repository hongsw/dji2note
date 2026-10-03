"""Zoom 로컬 녹화본 자동 처리.

Zoom은 회의가 끝나면 녹화를 변환해 '<녹화 폴더>/YYYY-MM-DD HH.MM.SS 회의 이름/' 에 저장한다.
  - audio*.m4a / video*.mp4 (또는 예전 이름 audio_only.m4a, zoom_0.mp4): 전원의 소리가 섞인 파일
  - Audio Record/audio<이름><숫자>.m4a: '참가자별로 별도 오디오 녹음' 설정 시 사람마다 한 파일
참가자별 파일이 있으면 사람마다 채널로 합쳐 화자를 실제 이름으로 정확히 나눈다.
"""
import json
import re
import time
from datetime import datetime
from pathlib import Path

DEFAULT_DIR = Path.home() / "Documents" / "Zoom"
FOLDER_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2})\.(\d{2})\.(\d{2})\s*(.*)$")
SETTLE_SEC = 60   # 변환이 끝나고 이만큼 변화가 없어야 처리 (변환 중 파일을 건드리지 않게)


def participant_name(path: Path) -> str:
    """'audio홍길동11234567890.m4a' → '홍길동'"""
    stem = re.sub(r"^audio", "", path.stem, flags=re.I)
    name = re.sub(r"\d{6,}$", "", stem).strip(" _-")
    return name or path.stem


def meeting_info(folder: Path) -> dict | None:
    """처리할 수 있는 녹화 폴더면 정보를, 아니면(변환 중·소리 없음) None."""
    m = FOLDER_RE.match(folder.name)
    if not m or not folder.is_dir():
        return None
    files = list(folder.rglob("*"))
    if any(f.suffix.lower() == ".zoom" for f in files):  # 아직 변환 중
        return None
    if files and time.time() - max(f.stat().st_mtime for f in files) < SETTLE_SEC:
        return None
    per_person = sorted((folder / "Audio Record").glob("*.m4a")) if (folder / "Audio Record").is_dir() else []
    mixed = (sorted(folder.glob("audio*.m4a")) or sorted(folder.glob("*.m4a"))
             or sorted(folder.glob("video*.mp4")) or sorted(folder.glob("zoom_*.mp4")) or sorted(folder.glob("*.mp4")))
    if not per_person and not mixed:
        return None
    start = datetime.strptime(f"{m.group(1)} {m.group(2)}:{m.group(3)}:{m.group(4)}", "%Y-%m-%d %H:%M:%S")
    chat = next((p for p in (folder / "chat.txt", folder / "meeting_saved_chat.txt") if p.exists()), None)
    return {"key": "zoom:" + folder.name, "folder": folder, "start": start, "topic": m.group(5).strip(),
            "participants": per_person if len(per_person) >= 2 else [], "mixed": mixed[0] if mixed else None,
            "chat": chat}


def find_meetings(root: Path) -> list[dict]:
    """녹화 폴더의 회의들(권한 없으면 PermissionError)."""
    return sorted((i for f in root.iterdir() if (i := meeting_info(f))), key=lambda i: i["start"])


def prepare_audio(info: dict, out_dir: Path) -> Path:
    """처리할 오디오 하나를 만든다: 참가자별이면 사람마다 채널로 합치고, 아니면 섞인 파일 그대로.

    녹음 옆에 <이름>.json(화자 이름·상황·회의 이름)을 남겨 파이프라인이 읽게 한다.
    """
    from . import transcribe
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = info["start"].strftime("%Y%m%d_%H%M%S")
    side = {"situation": "online", "title": info["topic"]}
    if info["participants"]:
        dst = out_dir / f"ZOOM_{stamp}.wav"
        if not dst.exists():
            transcribe.merge_channels(info["participants"], dst)
        side["speakers"] = [participant_name(p) for p in info["participants"]]
    else:
        src = info["mixed"]
        dst = out_dir / f"ZOOM_{stamp}{src.suffix.lower()}"
        if not dst.exists():
            dst.write_bytes(src.read_bytes())
    if info.get("chat"):
        side["chat"] = info["chat"].read_text(errors="replace")[:20000]
    dst.with_suffix(".json").write_text(json.dumps(side, ensure_ascii=False))
    return dst


# ── 웹에서 내려받은 Zoom 클라우드 녹화 (관리자 권한 없이 쓰는 방법) ──────────────
# 내 녹화 페이지에서 다운로드하면 'GMT20261003-053000_Recording.m4a',
# 'GMT20261003-053000_Recording_1920x1080.mp4', 'GMT…_RecordingnewChat.txt' 처럼
# 녹화 시작 시각(UTC)이 이름 앞에 붙는다. 이 시각으로 한 회의의 파일을 묶는다.

DOWNLOADS_DIR = Path.home() / "Downloads"
CLOUD_RE = re.compile(r"^GMT(\d{8})-(\d{6})_?(.*)$")
PARTIAL_EXTS = (".crdownload", ".download", ".part", ".partial")


def list_cloud_downloads(root: Path = DOWNLOADS_DIR) -> list[dict]:
    """점검용: 다운로드 폴더의 Zoom 녹화 묶음을 상태와 함께 (받는 중·소리 없음 포함)."""
    from datetime import timezone
    groups: dict[str, list[Path]] = {}
    for p in root.iterdir():
        m = CLOUD_RE.match(p.name)
        if m and p.is_file():
            groups.setdefault(f"{m.group(1)}-{m.group(2)}", []).append(p)
    rows = []
    for stamp, files in groups.items():
        real = [f for f in files if not re.search(r" \(\d+\)\.\w+$", f.name)]
        kinds = sorted({("영상" if f.suffix.lower() == ".mp4" else "오디오" if f.suffix.lower() == ".m4a"
                         else "채팅" if "chat" in f.name.lower() else "자막" if f.suffix.lower() == ".vtt"
                         else "받는 중" if f.name.endswith(PARTIAL_EXTS) else f.suffix.lstrip("."))
                        for f in real})
        start = (datetime.strptime(stamp, "%Y%m%d-%H%M%S").replace(tzinfo=timezone.utc).astimezone()
                 .replace(tzinfo=None))
        rows.append({"key": "zoomdl:GMT" + stamp, "start": start.isoformat(timespec="minutes"),
                     "kinds": kinds, "size_mb": round(sum(f.stat().st_size for f in real) / 1e6),
                     "downloading": any(f.name.endswith(PARTIAL_EXTS) for f in files),
                     "has_audio": any(f.suffix.lower() in (".m4a", ".mp4") for f in real)})
    return sorted(rows, key=lambda r: r["start"], reverse=True)


def find_cloud_downloads(root: Path = DOWNLOADS_DIR) -> list[dict]:
    """다운로드 폴더의 Zoom 클라우드 녹화 묶음 (권한 없으면 PermissionError)."""
    from datetime import timezone
    groups: dict[str, list[Path]] = {}
    for p in root.iterdir():
        m = CLOUD_RE.match(p.name)
        if m and p.is_file() and not re.search(r" \(\d+\)\.\w+$", p.name):  # '… (1).mp4' 중복 사본은 무시
            groups.setdefault(f"{m.group(1)}-{m.group(2)}", []).append(p)
    out = []
    now = time.time()
    for stamp, files in groups.items():
        if any(f.name.endswith(PARTIAL_EXTS) for f in files):  # 아직 내려받는 중
            continue
        if now - max(f.stat().st_mtime for f in files) < 30:
            continue
        audio = sorted(f for f in files if f.suffix.lower() == ".m4a")
        video = sorted((f for f in files if f.suffix.lower() == ".mp4"), key=lambda f: f.stat().st_size)
        mixed = audio[0] if audio else (video[0] if video else None)  # 영상은 가장 작은 해상도
        if not mixed:
            continue
        chat = next((f for f in files if f.suffix.lower() == ".txt" and "chat" in f.name.lower()), None)
        start = (datetime.strptime(stamp, "%Y%m%d-%H%M%S").replace(tzinfo=timezone.utc)
                 .astimezone().replace(tzinfo=None))
        out.append({"key": "zoomdl:GMT" + stamp, "folder": root, "start": start, "topic": "",
                    "participants": [], "mixed": mixed, "chat": chat})
    return sorted(out, key=lambda i: i["start"])
