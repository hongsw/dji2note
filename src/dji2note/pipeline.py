"""녹음 찾기 → 로컬 복사 → 세션 묶기 → 받아쓰기 → 스크립트·요약 → 업로드."""
import fcntl
import json
import re
import shutil
import sys
import subprocess
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

from . import config, llm, notion, transcribe, upload
from .config import Config

# DJI Mic / Mic 2 / Mic Mini 파일명: TX00_MIC025_20260928_112702_orig.wav
DJI_RE = re.compile(r"^(TX|RX)\d*_MIC(\d+)_(\d{8})_(\d{6})(?:_\w+)?\.wav$", re.I)
APP_REC_RE = re.compile(r"^(REC|MEET|ZOOM)_(\d{8})_(\d{6})", re.I)
GROUP_GAP_SEC = 90     # 앞 파일 끝과 이 간격 이내로 이어지면 한 세션(분할 저장 파일)
MIN_TEXT_CHARS = 40    # 전사가 이보다 짧으면 대화 없음


def log(msg):
    """화면(앱의 파이프)과 로그 파일 양쪽에 쓴다.

    앱이 종료·교체돼 파이프가 끊겨도 엔진은 계속 돌고, 다시 켜진 앱은 로그 파일을 이어 읽는다.
    """
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    try:
        print(line, flush=True)
    except (BrokenPipeError, OSError):
        pass
    try:
        config.LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(config.LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


class _SafeStream:
    """앱이 종료돼 파이프가 닫혀도 쓰기 오류로 죽지 않도록 감싼 출력(tqdm 진행률 포함)."""

    def __init__(self, stream):
        self._s = stream

    def write(self, data):
        try:
            return self._s.write(data)
        except (BrokenPipeError, OSError, ValueError):
            return len(data)

    def flush(self):
        try:
            self._s.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def __getattr__(self, name):
        return getattr(self._s, name)


def mark_running():
    """긴 작업 시작: 앱이 꺼지거나 바뀌어도 계속 돌고, 다시 켜진 앱이 진행 상황에 붙을 수 있게."""
    import atexit
    import os
    import signal
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    sys.stdout, sys.stderr = _SafeStream(sys.stdout), _SafeStream(sys.stderr)
    config.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    config.RUN_FILE.write_text(json.dumps({"pid": os.getpid(), "started": datetime.now().isoformat()}))
    atexit.register(lambda: config.RUN_FILE.unlink(missing_ok=True))


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
    app = APP_REC_RE.match(path.name)
    if m:
        start = datetime.strptime(m.group(3) + m.group(4), "%Y%m%d%H%M%S")
        label = f"MIC{int(m.group(2)):03d}"
    elif app:
        # 앱에서 녹음한 파일: REC_20261001_103015.wav(마이크) / MEET_…(온라인 회의)
        start = datetime.strptime(app.group(2) + app.group(3), "%Y%m%d%H%M%S")
        label = {"REC": "녹음", "MEET": "온라인회의", "ZOOM": "Zoom"}[app.group(1).upper()]
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


def sidecar(src: Path) -> dict:
    """녹음 옆의 <이름>.json — 채널별 화자 이름(speakers), 상황(situation). 앱 녹음이 만든다."""
    side = src.with_suffix(".json")
    if side.exists():
        try:
            return json.loads(side.read_text())
        except ValueError:
            return {}
    return {}


def speakers_for(src: Path) -> list[str] | None:
    return sidecar(src).get("speakers") or None


SPEAKER_RE = re.compile(r"^\*\*\[[\d:]+\] ([^:*]+?):\*\*", re.M)


def count_speakers(transcript: str) -> int:
    """대본의 '**[00:00] 이름:**' 에서 서로 다른 화자 수 ('(?)' 표시는 같은 사람으로)."""
    names = {re.sub(r"\s*\(\?\)\s*$", "", n).strip() for n in SPEAKER_RE.findall(transcript)}
    return len({n for n in names if n and n != "?"})


def fmt_duration(sec: float) -> str:
    s = int(sec)
    h, m, s = s // 3600, s // 60 % 60, s % 60
    return f"{h}시간 {m}분 {s}초" if h else f"{m}분 {s}초"


def read_meta(folder: Path) -> dict:
    """회의록 폴더의 meta.json. 없으면(이전 버전) 대본·요약에서 계산해 채운다."""
    meta = {}
    if (folder / "meta.json").exists():
        try:
            meta = json.loads((folder / "meta.json").read_text())
        except ValueError:
            meta = {}
    transcript = (folder / "transcript.md").read_text() if (folder / "transcript.md").exists() else ""
    summary = (folder / "summary.md").read_text() if (folder / "summary.md").exists() else ""
    if "duration" not in meta:
        head = (transcript or summary).split("\n", 1)[0]
        m = re.search(r"(?:(\d+)시간 )?(\d+)분(?: (\d+)초)?", head)
        meta["duration"] = (int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3) or 0)) if m else 0
    if "speakers" not in meta:
        meta["speakers"] = count_speakers(transcript)
    if "topic" not in meta:
        line = next((l for l in summary.splitlines() if "주제:" in l), "")
        meta["topic"] = line.replace("**", "").split("주제:", 1)[-1].strip() if line else ""
    m = re.match(r"(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})", folder.name)
    meta.setdefault("start", f"{m.group(1)}T{m.group(2)}:{m.group(3)}:00" if m else "")
    meta.setdefault("situation", "")
    return meta


def transcript_doc(title: str, body: str, backend: str, speakers: list[str] | None = None) -> str:
    how = "Claude" if backend != "none" else "음량 기준 자동 분리(LLM 미사용 — 부정확할 수 있음)"
    who = ("- 화자는 **녹음 채널로 구분**: " + ", ".join(f"**{s}**" for s in speakers) + ", `(?)` = 겹쳐 말해 불확실\n"
           if speakers else "- **A** = 마이크 착용자, **B** = 상대방, `(?)` = 화자 판정 불확실\n")
    return (f"# 대화 스크립트 — {title}\n\n"
            f"- 받아쓰기: Whisper / 화자 분리·교정: {how}\n"
            + who +
            "- 음성인식 오류 교정은 `[원문: …]`, 알아듣기 어려운 부분은 `[불명확]`\n\n---\n\n"
            f"{body.strip()}\n")


def process_session(cfg: Config, group: list[dict], copy: bool = True, index: tuple[int, int] | None = None) -> dict:
    first, last = group[0], group[-1]
    total = sum(r["duration"] for r in group)
    label = first["label"] if len(group) == 1 else f"{first['label']}-{last['label']}"
    folder = cfg.notes_dir / f"{first['start']:%Y-%m-%d_%H%M}_{label}"
    title = f"{first['start']:%Y-%m-%d %H:%M} ({int(total // 60)}분 {int(total % 60)}초)"
    side = sidecar(Path(first["src"]))
    if side.get("title"):  # Zoom 회의 이름 등
        title += f" · {side['title']}"
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
            raw = transcribe.transcribe(inputs, Path(tmp), cfg.whisper_model, cfg.language,
                                        speakers=speakers_for(Path(group[0]["src"])), progress_log=log)
    if len(re.sub(r"^\[.*?\|", "", raw, flags=re.M).strip()) < MIN_TEXT_CHARS:
        log(f"대화 없음: {folder.name}")
        return {"status": "no_speech"}

    folder.mkdir(parents=True, exist_ok=True)
    (folder / "raw_whisper.txt").write_text(raw + "\n")
    from . import situations
    situation = sidecar(Path(first["src"])).get("situation") or cfg.default_situation
    if situation == "auto" and cfg.llm_backend != "none":
        situation = llm.classify(cfg, raw)
    log(f"상황: {situations.get(situation)['title']}")
    if cfg.llm_backend == "none":
        body = transcribe.label_by_loudness(raw)
        (folder / "transcript.md").write_text(transcript_doc(title, body, "none", speakers_for(Path(first["src"]))))
    else:
        body = llm.make_transcript(cfg, raw, log=log, cache_dir=folder / ".chunks", situation=situation)
        if side.get("chat"):  # Zoom 회의 중 채팅도 요약에 반영
            body += "\n\n## 회의 중 채팅\n\n" + "\n".join(f"- {l.strip()}" for l in side["chat"].splitlines() if l.strip())
        transcript = transcript_doc(title, body, cfg.llm_backend, speakers_for(Path(first["src"])))
        (folder / "transcript.md").write_text(transcript)
        log(f"요약 작성 중 ({cfg.llm_model or '기본 모델'})")
        (folder / "summary.md").write_text(llm.make_summary(cfg, title, transcript, situation))
        shutil.rmtree(folder / ".chunks", ignore_errors=True)  # 다 끝났으면 조각 캐시 정리
    transcript_text = (folder / "transcript.md").read_text()
    summary_text = (folder / "summary.md").read_text() if (folder / "summary.md").exists() else ""
    topic = next((l.replace("**", "").split("주제:", 1)[-1].strip() for l in summary_text.splitlines() if "주제:" in l), "")
    (folder / "meta.json").write_text(json.dumps({
        "situation": situation, "duration": round(total), "start": first["start"].isoformat(),
        "speakers": count_speakers(transcript_text), "topic": topic,
        "files": [r["name"] for r in group]}, ensure_ascii=False, indent=1))
    log(f"저장: {folder}")

    result = {"status": "done", "notes": str(folder), "situation": situation}
    if cfg.upload == "rclone":
        result["drive"] = upload.upload(cfg, folder)
        result["drive_url"] = upload.folder_url(cfg, folder.name)
        log(f"업로드: {result['drive']}")
    if cfg.notion_enabled:
        # Notion 실패는 회의 처리 실패로 보지 않는다 — `dji2note publish --notion` 으로 다시 올림
        try:
            log("Notion에 올리는 중")
            result["notion_url"] = notion.publish(cfg, folder, result.get("drive_url", ""))
            log(f"Notion: {result['notion_url']}")
        except Exception as e:
            log(f"Notion 올리기 실패(회의록은 저장됨): {e}")
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


VOICE_MEMOS = Path.home() / "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
MEMO_EXTS = (".m4a", ".qta", ".wav")


def find_voice_memos() -> list[dict]:
    """Mac 음성 메모(iCloud로 동기화된 iPhone 메모 포함). 녹음 중인 파일은 30초간 변화 없을 때까지 제외.

    이 폴더는 macOS가 보호하므로 '전체 디스크 접근' 권한이 없으면 PermissionError.
    """
    now = time.time()
    recs = []
    for p in VOICE_MEMOS.iterdir():  # 권한 없으면 여기서 PermissionError
        if p.suffix.lower() in MEMO_EXTS and now - p.stat().st_mtime > 30:
            r = recording_info(p)
            r["key"] = "memo:" + p.name
            recs.append(r)
    return sorted(recs, key=lambda r: r["start"])


def run_memos(cfg: Config, dry_run: bool = False, skip_existing: bool = False, include_seen: bool = False):
    """새 음성 메모를 처리한다(앱이 폴더 변화를 감지하면 호출)."""
    state = config.load_state()
    try:
        memos = find_voice_memos()
    except PermissionError:
        log("음성 메모 폴더 접근 권한이 없습니다 — 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근에서 허용")
        return 2
    new = [r for r in memos if r["key"] not in state
           or (include_seen and state[r["key"]].get("status") == "seen")]
    if skip_existing:
        now = datetime.now().isoformat(timespec="seconds")
        for r in new:
            state[r["key"]] = {"status": "seen", "at": now}
        config.save_state(state)
        log(f"기존 음성 메모 {len(new)}개는 건너뜁니다")
        return 0
    if dry_run:
        for r in new:
            print(f"  {r['start']:%Y-%m-%d %H:%M}  {r['name']}")
        return 0
    lock = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("이미 실행 중")
        return 0
    for i, r in enumerate(new, 1):
        r["duration"] = duration(r["src"])
        if r["duration"] <= 5:
            state[r["key"]] = {"status": "no_speech", "reason": "too_short", "at": datetime.now().isoformat(timespec="seconds")}
            continue
        try:
            res = process_session(cfg, [r], copy=False, index=(i, len(new)))
            state[r["key"]] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
        except Exception as e:
            log(f"실패: {r['name']}: {e}")
        config.save_state(state)
    log(f"전체 완료: 음성 메모 {len(new)}개 확인")
    return 0


def run_zoom(cfg: Config, dry_run: bool = False, skip_existing: bool = False, include_seen: bool = False):
    """Zoom 로컬 녹화 폴더의 새 회의를 처리한다(앱이 폴더 변화를 감지하면 호출)."""
    from . import zoom
    root = Path(cfg.zoom_dir).expanduser() if cfg.zoom_dir else zoom.DEFAULT_DIR
    state = config.load_state()
    try:
        meetings = zoom.find_meetings(root)
    except PermissionError:
        log(f"Zoom 녹화 폴더 접근 권한이 없습니다 — {root} (시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더 또는 전체 디스크 접근)")
        return 2
    except FileNotFoundError:
        log(f"Zoom 녹화 폴더가 없습니다: {root}")
        return 1
    new = [m for m in meetings if m["key"] not in state
           or (include_seen and state[m["key"]].get("status") == "seen")]
    now = datetime.now().isoformat(timespec="seconds")
    if skip_existing:
        for m in new:
            state[m["key"]] = {"status": "seen", "at": now}
        config.save_state(state)
        log(f"기존 Zoom 녹화 {len(new)}개는 건너뜁니다")
        return 0
    if dry_run:
        for m in new:
            who = f"참가자 {len(m['participants'])}명 따로" if m["participants"] else "섞인 소리"
            print(f"  {m['start']:%Y-%m-%d %H:%M}  {m['topic'] or '(이름 없음)'}  — {who}")
        return 0
    lock = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("이미 실행 중")
        return 0
    for i, m in enumerate(new, 1):
        try:
            log(f"Zoom 녹화 준비 [{i}/{len(new)}]: {m['topic'] or m['folder'].name}"
                + (f" (참가자 {len(m['participants'])}명 따로)" if m["participants"] else ""))
            audio = zoom.prepare_audio(m, cfg.recordings_dir)
            rec = recording_info(audio) | {"duration": duration(audio)}
            res = process_session(cfg, [rec], copy=False, index=(i, len(new)))
            state[m["key"]] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
        except Exception as e:
            log(f"실패: {m['folder'].name}: {e}")
        config.save_state(state)
    log(f"전체 완료: Zoom 녹화 {len(new)}개 확인")
    return 0


def run_zoom_downloads(cfg: Config, root: Path | None = None, dry_run: bool = False,
                       skip_existing: bool = False, include_seen: bool = False):
    """다운로드 폴더에 내려받은 Zoom 클라우드 녹화를 처리한다(앱이 폴더 변화를 감지하면 호출)."""
    from . import zoom
    root = root or zoom.DOWNLOADS_DIR
    state = config.load_state()
    try:
        meetings = zoom.find_cloud_downloads(root)
    except PermissionError:
        log(f"다운로드 폴더 접근 권한이 없습니다 — {root}")
        return 2
    new = [m for m in meetings if m["key"] not in state
           or (include_seen and state[m["key"]].get("status") == "seen")]
    now = datetime.now().isoformat(timespec="seconds")
    if skip_existing:
        for m in new:
            state[m["key"]] = {"status": "seen", "at": now}
        config.save_state(state)
        log(f"기존 Zoom 다운로드 {len(new)}개는 건너뜁니다")
        return 0
    if dry_run:
        for m in new:
            print(f"  {m['start']:%Y-%m-%d %H:%M}  {m['mixed'].name}" + ("  + 채팅" if m["chat"] else ""))
        return 0
    lock = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("이미 실행 중")
        return 0
    for i, m in enumerate(new, 1):
        try:
            log(f"Zoom 녹화 준비 [{i}/{len(new)}]: {m['mixed'].name} (다운로드)")
            audio = zoom.prepare_audio(m, cfg.recordings_dir)
            rec = recording_info(audio) | {"duration": duration(audio)}
            res = process_session(cfg, [rec], copy=False, index=(i, len(new)))
            state[m["key"]] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
        except Exception as e:
            log(f"실패: {m['mixed'].name}: {e}")
        config.save_state(state)
    log(f"전체 완료: Zoom 다운로드 {len(new)}개 확인")
    return 0


def run_zoom_cloud(cfg: Config, dry_run: bool = False, skip_existing: bool = False,
                   include_seen: bool = False, days: int | None = None):
    """Zoom 클라우드의 새 녹화를 내려받아 처리한다(앱이 15분마다 호출)."""
    from . import zoom, zoom_cloud
    state = config.load_state()
    try:
        meetings = zoom_cloud.list_meetings(cfg, days or cfg.zoom_cloud_days)
    except zoom_cloud.ZoomError as e:
        log(f"실패: {e}")
        return 2
    new = [m for m in meetings if zoom_cloud.is_ready(m)
           and (("zoomcloud:" + m["uuid"]) not in state
                or (include_seen and state["zoomcloud:" + m["uuid"]].get("status") == "seen"))]
    now = datetime.now().isoformat(timespec="seconds")
    if skip_existing:
        for m in new:
            state["zoomcloud:" + m["uuid"]] = {"status": "seen", "at": now}
        config.save_state(state)
        log(f"기존 Zoom 클라우드 녹화 {len(new)}개는 건너뜁니다")
        return 0
    if dry_run:
        for m in new:
            p = zoom_cloud.pick_files(m)
            how = f"참가자 {len(p['people'])}명 따로" if p["people"] else ("오디오" if p["audio"] else "영상")
            print(f"  {m['start_time'][:16].replace('T', ' ')}  {m.get('topic', '')}  — {how}")
        return 0
    lock = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("이미 실행 중")
        return 0
    work = cfg.recordings_dir / "zoom-cloud"
    for i, m in enumerate(new, 1):
        key = "zoomcloud:" + m["uuid"]
        try:
            log(f"Zoom 녹화 준비 [{i}/{len(new)}]: {m.get('topic', '')} (클라우드)")
            info = zoom_cloud.fetch(cfg, m, work, log)
            audio = zoom.prepare_audio(info, cfg.recordings_dir)
            rec = recording_info(audio) | {"duration": duration(audio)}
            res = process_session(cfg, [rec], copy=False, index=(i, len(new)))
            state[key] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
            shutil.rmtree(info["folder"], ignore_errors=True)  # 원본 내려받은 것은 정리(합친 오디오는 남김)
        except Exception as e:
            log(f"실패: {m.get('topic', m['uuid'])}: {e}")
        config.save_state(state)
    log(f"전체 완료: Zoom 클라우드 녹화 {len(new)}개 확인")
    return 0


def mark_seen(names: list[str]):
    state = config.load_state()
    now = datetime.now().isoformat(timespec="seconds")
    for n in names:
        state.setdefault(n, {"status": "seen", "at": now})
    config.save_state(state)
