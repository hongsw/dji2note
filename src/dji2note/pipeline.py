"""녹음 찾기 → 로컬 복사 → 세션 묶기 → 받아쓰기 → 스크립트·요약 → 업로드."""
import fcntl
import re
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

from . import config, llm, transcribe, upload
from .config import Config

# DJI Mic / Mic 2 / Mic Mini 파일명: TX00_MIC025_20260928_112702_orig.wav
DJI_RE = re.compile(r"^(TX|RX)\d*_MIC(\d+)_(\d{8})_(\d{6})(?:_\w+)?\.wav$", re.I)
GROUP_GAP_SEC = 90     # 앞 파일 끝과 이 간격 이내로 이어지면 한 세션(분할 저장 파일)
MIN_TEXT_CHARS = 40    # 전사가 이보다 짧으면 대화 없음


def log(msg):
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


def notify(cfg: Config, msg: str):
    if cfg.notify:
        safe = msg.replace('"', "'")
        subprocess.run(["osascript", "-e", f'display notification "{safe}" with title "dji2note"'],
                       check=False, capture_output=True)


def duration(path: Path) -> float:
    """ffprobe 없이 ffmpeg 출력의 Duration 줄로 길이를 구한다."""
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path)], capture_output=True, text=True)
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", out.stderr)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0


def recording_info(path: Path) -> dict:
    m = DJI_RE.match(path.name)
    if m:
        start = datetime.strptime(m.group(3) + m.group(4), "%Y%m%d%H%M%S")
        label = f"MIC{int(m.group(2)):03d}"
    else:
        start = datetime.fromtimestamp(path.stat().st_mtime)
        label = re.sub(r"[^\w가-힣-]+", "_", path.stem)[:40]
    return {"src": path, "name": path.name, "label": label, "start": start}


def find_dji_recordings() -> list[dict]:
    """마운트된 볼륨에서 DJI 녹음 파일을 찾는다(볼륨 루트와 한 단계 하위 폴더)."""
    found = []
    for vol in Path("/Volumes").iterdir():
        if vol.name.startswith(".") or vol.is_symlink():
            continue
        try:
            for p in [*vol.glob("*.wav"), *vol.glob("*/*.wav")]:
                if DJI_RE.match(p.name) and not p.name.startswith("._"):
                    found.append(recording_info(p))
        except OSError as e:
            log(f"볼륨 읽기 실패 {vol}: {e}")
    return sorted(found, key=lambda r: r["start"])


def copy_local(cfg: Config, rec: dict) -> Path:
    """DJI 볼륨은 연결이 끊기기 쉬워 먼저 로컬로 복사한다(재시도 포함)."""
    cfg.recordings_dir.mkdir(parents=True, exist_ok=True)
    dst = cfg.recordings_dir / rec["name"]
    size = rec["src"].stat().st_size
    if dst.exists() and dst.stat().st_size == size:
        return dst
    for attempt in range(3):
        try:
            shutil.copy2(rec["src"], dst)
            if dst.stat().st_size == size:
                return dst
        except OSError as e:
            log(f"복사 실패({attempt + 1}/3) {rec['name']}: {e}")
            time.sleep(3)
    raise RuntimeError(f"복사 실패: {rec['name']}")


def group_sessions(recs: list[dict]) -> list[list[dict]]:
    """DJI는 긴 녹음을 30분 단위로 나눠 저장하므로 연속 파일을 한 세션으로 묶는다."""
    groups = []
    for r in recs:
        if groups:
            prev = groups[-1][-1]
            if r["start"] <= prev["start"] + timedelta(seconds=prev["duration"] + GROUP_GAP_SEC):
                groups[-1].append(r)
                continue
        groups.append([r])
    return groups


def transcript_doc(title: str, body: str, backend: str) -> str:
    how = "Claude" if backend != "none" else "음량 기준 자동 분리(LLM 미사용 — 부정확할 수 있음)"
    return (f"# 대화 스크립트 — {title}\n\n"
            f"- 받아쓰기: Whisper / 화자 분리·교정: {how}\n"
            "- **A** = 마이크 착용자, **B** = 상대방, `(?)` = 화자 판정 불확실\n"
            "- 음성인식 오류 교정은 `[원문: …]`, 알아듣기 어려운 부분은 `[불명확]`\n\n---\n\n"
            f"{body.strip()}\n")


def process_session(cfg: Config, group: list[dict], copy: bool = True, index: tuple[int, int] | None = None) -> dict:
    first, last = group[0], group[-1]
    total = sum(r["duration"] for r in group)
    label = first["label"] if len(group) == 1 else f"{first['label']}-{last['label']}"
    folder = cfg.notes_dir / f"{first['start']:%Y-%m-%d_%H%M}_{label}"
    title = f"{first['start']:%Y-%m-%d %H:%M} ({int(total // 60)}분 {int(total % 60)}초)"
    pos = f" [{index[0]}/{index[1]}]" if index else ""
    log(f"처리 시작{pos}: {folder.name} (파일 {len(group)}개, {total / 60:.1f}분)")

    cached = folder / "raw_whisper.txt"
    if cached.exists() and cached.stat().st_size > 0:
        # 중간에 멈췄던 회의: 받아쓰기 결과를 재사용하고 AI 단계부터 이어서
        log(f"받아쓰기 결과 재사용: {cached.name}")
        raw = cached.read_text().strip()
    else:
        inputs = [copy_local(cfg, r) if copy else r["src"] for r in group]
        with tempfile.TemporaryDirectory() as tmp:
            raw = transcribe.transcribe(inputs, Path(tmp), cfg.whisper_model, cfg.language)
    if len(re.sub(r"^\[.*?\|", "", raw, flags=re.M).strip()) < MIN_TEXT_CHARS:
        log(f"대화 없음: {folder.name}")
        return {"status": "no_speech"}

    folder.mkdir(parents=True, exist_ok=True)
    (folder / "raw_whisper.txt").write_text(raw + "\n")
    if cfg.llm_backend == "none":
        body = transcribe.label_by_loudness(raw)
        (folder / "transcript.md").write_text(transcript_doc(title, body, "none"))
    else:
        body = llm.make_transcript(cfg, raw, log=log)
        transcript = transcript_doc(title, body, cfg.llm_backend)
        (folder / "transcript.md").write_text(transcript)
        log(f"요약 작성 중 ({cfg.llm_model})")
        (folder / "summary.md").write_text(llm.make_summary(cfg, title, transcript))
    log(f"저장: {folder}")

    result = {"status": "done", "notes": str(folder)}
    if cfg.upload == "rclone":
        result["drive"] = upload.upload(cfg, folder)
        result["drive_url"] = upload.folder_url(cfg, folder.name)
        log(f"업로드: {result['drive']}")
    return result


def run(cfg: Config, dry_run: bool = False, include_seen: bool = False, names: list[str] | None = None):
    """연결된 DJI의 녹음을 한 번에 처리한다.

    기본은 새 녹음만, include_seen이면 건너뛰기 표시한 것까지, names를 주면 그 파일들만.
    먼저 전부 Mac으로 복사한 뒤 처리하므로, 복사가 끝나면 DJI를 분리해도 된다.
    """
    config.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("이미 실행 중")
        return

    time.sleep(0 if dry_run else 3)  # 마운트 직후 안정화
    state = config.load_state()
    if names:
        wanted = set(names)
        recs = [r for r in find_dji_recordings() if r["name"] in wanted]
    else:
        skip = {"done", "no_speech"} | (set() if include_seen else {"seen"})
        recs = [r for r in find_dji_recordings() if state.get(r["name"], {}).get("status") not in skip]
    now = datetime.now().isoformat(timespec="seconds")

    def mark_too_short(items):
        # 너무 짧은 파일도 기록해 두어야 '남은 녹음' 수가 0이 된다
        for r in items:
            state[r["name"]] = {"status": "no_speech", "reason": "too_short", "at": now}

    if not dry_run:
        mark_too_short([r for r in recs if r["src"].stat().st_size <= 64 * 1024])
    recs = [r for r in recs if r["src"].stat().st_size > 64 * 1024]  # 0바이트·초단편 제외
    if not recs:
        if not dry_run:
            config.save_state(state)
        if dry_run:
            print("처리할 녹음이 없습니다.")
        return
    if dry_run:
        for r in recs:
            r["duration"] = duration(r["src"])
        for g in group_sessions(recs):
            print(f"  {g[0]['start']:%Y-%m-%d %H:%M}  {sum(r['duration'] for r in g) / 60:5.1f}분  "
                  + ", ".join(r["name"] for r in g))
        return

    # 1) 전부 먼저 복사 — 긴 일괄 처리 중에 DJI가 빠지거나 연결이 끊겨도 안전
    for i, r in enumerate(recs, 1):
        log(f"복사 [{i}/{len(recs)}]: {r['name']}")
        try:
            r["src"] = copy_local(cfg, r)
        except Exception as e:
            log(f"실패: {r['name']}: {e}")
            r["src"] = None
    recs = [r for r in recs if r["src"]]
    log("복사 완료 — 이제 DJI를 분리해도 됩니다")
    for r in recs:
        r["duration"] = duration(r["src"])
    mark_too_short([r for r in recs if r["duration"] <= 5])
    config.save_state(state)
    recs = [r for r in recs if r["duration"] > 5]
    if not recs:
        log("전체 완료: 처리할 녹음이 없습니다 (너무 짧은 파일만 있음)")
        return

    # 2) 최신 녹음부터 처리 — 밀린 녹음이 많아도 방금 한 회의가 먼저 나온다
    groups = list(reversed(group_sessions(recs)))
    log(f"녹음 {len(recs)}개 → 회의 {len(groups)}건 처리")
    notify(cfg, f"회의 {len(groups)}건 처리 시작 — DJI를 분리해도 됩니다")
    ok = failed = 0
    for i, g in enumerate(groups, 1):
        try:
            res = process_session(cfg, g, copy=False, index=(i, len(groups)))
            ok += res["status"] == "done"
        except Exception as e:  # 한 회의 실패가 나머지를 막지 않도록 (기록이 안 남아 다음에 재시도됨)
            failed += 1
            log(f"실패: {g[0]['name']}: {e}")
            continue
        for r in g:
            state[r["name"]] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
        config.save_state(state)
    log(f"전체 완료: 성공 {ok}건" + (f", 실패 {failed}건" if failed else ""))
    if ok or failed:
        notify(cfg, f"{ok}건 정리 완료" + (f" · {failed}건 실패" if failed else "")
               + (" · Google Drive 업로드됨" if ok and cfg.upload == "rclone" else ""))


def mark_seen(names: list[str]):
    state = config.load_state()
    now = datetime.now().isoformat(timespec="seconds")
    for n in names:
        state.setdefault(n, {"status": "seen", "at": now})
    config.save_state(state)
