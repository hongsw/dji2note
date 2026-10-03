"""Zoom 클라우드 녹화 가져오기 (Server-to-Server OAuth 앱).

준비(계정 관리자 1회): Zoom App Marketplace → Develop → Build App → Server-to-Server OAuth
  - 범위(Scopes): cloud_recording:read:list_user_recordings:admin, cloud_recording:read:recording:admin
    (구 방식이면 recording:read:admin)
  - 앱을 Activate 한 뒤 Account ID / Client ID / Client Secret 을 dji2note 설정에 넣는다.

녹화마다 참가자별 오디오(있으면) → 섞인 오디오(M4A) → 영상(MP4) 순으로 하나를 골라 내려받고,
채팅 파일도 받아 로컬 Zoom 녹화와 같은 방식으로 처리한다.
"""
import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from .config import Config

# 시험용 가짜 서버로 바꿀 수 있게 (DJI2NOTE_ZOOM_OAUTH / DJI2NOTE_ZOOM_API)
OAUTH = os.environ.get("DJI2NOTE_ZOOM_OAUTH", "https://zoom.us/oauth/token")
API = os.environ.get("DJI2NOTE_ZOOM_API", "https://api.zoom.us/v2")

_token: dict = {}


class ZoomError(RuntimeError):
    pass


def _http(req: urllib.request.Request, timeout=60) -> bytes:
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            msg = json.loads(body).get("reason") or json.loads(body).get("message") or body
        except ValueError:
            msg = body
        hint = {400: " — Account ID·Client ID·Secret을 확인하세요",
                401: " — 앱이 Activate 됐는지, 값이 맞는지 확인하세요",
                403: " — 앱 범위(Scopes)에 클라우드 녹화 읽기 권한을 추가하세요"}.get(e.code, "")
        raise ZoomError(f"Zoom {e.code}: {str(msg)[:200]}{hint}") from None
    except urllib.error.URLError as e:
        raise ZoomError(f"Zoom 연결 실패: {e.reason}") from None


def token(cfg: Config) -> str:
    """account_credentials 방식 액세스 토큰(1시간). 만료 1분 전까지 재사용."""
    if _token.get("value") and _token.get("exp", 0) > time.time() + 60:
        return _token["value"]
    if not (cfg.zoom_account_id and cfg.zoom_client_id and cfg.zoom_client_secret):
        raise ZoomError("Zoom 클라우드 연결 정보(Account ID·Client ID·Client Secret)가 없습니다")
    basic = base64.b64encode(f"{cfg.zoom_client_id}:{cfg.zoom_client_secret}".encode()).decode()
    url = f"{OAUTH}?" + urllib.parse.urlencode({"grant_type": "account_credentials",
                                                 "account_id": cfg.zoom_account_id})
    data = json.loads(_http(urllib.request.Request(url, method="POST", data=b"",
                                                   headers={"Authorization": f"Basic {basic}"})))
    _token.update(value=data["access_token"], exp=time.time() + int(data.get("expires_in", 3600)))
    return _token["value"]


def _get(cfg: Config, path: str, params: dict) -> dict:
    url = f"{API}{path}?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token(cfg)}"})
    return json.loads(_http(req))


def list_meetings(cfg: Config, days: int = 30) -> list[dict]:
    """최근 days일의 클라우드 녹화 회의(오래된 것부터). API는 한 번에 최대 30일 구간만 받는다."""
    user = urllib.parse.quote(cfg.zoom_user or "me")
    end = date.today()
    meetings: dict[str, dict] = {}
    while days > 0:
        span = min(days, 30)
        start = end - timedelta(days=span)
        params = {"from": start.isoformat(), "to": end.isoformat(), "page_size": 300}
        while True:
            data = _get(cfg, f"/users/{user}/recordings", params)
            for m in data.get("meetings", []):
                meetings[m["uuid"]] = m
            if not data.get("next_page_token"):
                break
            params["next_page_token"] = data["next_page_token"]
        end, days = start, days - span
    return sorted(meetings.values(), key=lambda m: m.get("start_time", ""))


def is_ready(m: dict) -> bool:
    files = m.get("recording_files", []) + m.get("participant_audio_files", [])
    return bool(files) and all(f.get("status", "completed") == "completed" for f in files)


def pick_files(m: dict) -> dict:
    """처리에 쓸 파일: 참가자별 오디오(2명 이상) / 섞인 오디오 / 영상 / 채팅."""
    rec = m.get("recording_files", [])
    people = [f for f in m.get("participant_audio_files", []) if f.get("download_url")]
    audio = next((f for f in rec if f.get("file_type") == "M4A"), None)
    video = next((f for f in rec if f.get("file_type") == "MP4"), None)
    chat = next((f for f in rec if f.get("file_type") == "CHAT"), None)
    return {"people": people if len(people) >= 2 else [], "audio": audio, "video": video, "chat": chat}


def download(cfg: Config, f: dict, dst: Path, log=print) -> Path:
    if dst.exists() and f.get("file_size") and dst.stat().st_size == f["file_size"]:
        return dst
    tmp = dst.with_suffix(dst.suffix + ".part")
    url = urllib.parse.quote(f["download_url"], safe=":/?&=%#+@,;~")  # 주소에 한글 등이 있어도 안전하게
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token(cfg)}"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r, open(tmp, "wb") as out:
            while chunk := r.read(1 << 20):
                out.write(chunk)
    except urllib.error.HTTPError as e:
        raise ZoomError(f"내려받기 실패 {e.code}: {f.get('file_type')} {dst.name}") from None
    tmp.replace(dst)
    return dst


def fetch(cfg: Config, m: dict, work: Path, log=print) -> dict:
    """회의 하나를 내려받아 zoom.prepare_audio 가 쓰는 정보로 돌려준다."""
    start = datetime.fromisoformat(m["start_time"].replace("Z", "+00:00")).astimezone().replace(tzinfo=None)
    folder = work / f"zoomcloud_{start:%Y%m%d_%H%M%S}"
    folder.mkdir(parents=True, exist_ok=True)
    picked = pick_files(m)
    participants, mixed, chat = [], None, None
    if picked["people"]:
        log(f"참가자별 오디오 {len(picked['people'])}개 내려받는 중")
        for i, f in enumerate(picked["people"], 1):
            name = (f.get("file_name") or f"참가자{i}").replace("/", "_")
            participants.append(download(cfg, f, folder / f"audio{name}{i:06d}.m4a", log))
    else:
        f = picked["audio"] or picked["video"]
        if not f:
            raise ZoomError("소리 파일(M4A·MP4)이 없는 녹화입니다")
        ext = ".m4a" if f is picked["audio"] else ".mp4"
        log(f"{'오디오' if ext == '.m4a' else '영상'} 내려받는 중 ({(f.get('file_size') or 0) / 1e6:.0f}MB)")
        mixed = download(cfg, f, folder / f"audio{ext}", log)
    if picked["chat"]:
        chat = download(cfg, picked["chat"], folder / "chat.txt", log)
    return {"key": "zoomcloud:" + m["uuid"], "start": start, "topic": m.get("topic", ""),
            "participants": participants, "mixed": mixed, "chat": chat, "folder": folder}
