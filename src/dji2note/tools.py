"""외부 도구(ffmpeg, rclone, claude) 위치 찾기와 자동 준비. Homebrew 없이도 동작하게 한다."""
import io
import os
import shutil
import urllib.request
import zipfile
from pathlib import Path

from .config import CONFIG_DIR

# Mac 앱(DJI2Note.app)과 CLI가 함께 쓰는 도구 폴더
APP_BIN = Path.home() / "Library" / "Application Support" / "DJI2Note" / "bin"
SHIM_BIN = CONFIG_DIR / "bin"
RCLONE_URL = "https://downloads.rclone.org/rclone-current-osx-arm64.zip"


def setup_path():
    """launchd·GUI에서 실행돼도 도구를 찾도록 PATH를 보강하고 ffmpeg가 없으면 내장본을 연결한다."""
    dirs = [SHIM_BIN, APP_BIN, Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]
    current = os.environ.get("PATH", "/usr/bin:/bin").split(":")
    os.environ["PATH"] = ":".join([str(d) for d in dirs if str(d) not in current] + current)
    if not shutil.which("ffmpeg"):
        try:
            import imageio_ffmpeg
            SHIM_BIN.mkdir(parents=True, exist_ok=True)
            link = SHIM_BIN / "ffmpeg"
            link.unlink(missing_ok=True)
            link.symlink_to(imageio_ffmpeg.get_ffmpeg_exe())
        except Exception:
            pass


def ffmpeg():
    return shutil.which("ffmpeg")


def rclone():
    return shutil.which("rclone")


def claude():
    return shutil.which("claude")


def install_rclone() -> str:
    """공식 배포본을 내려받아 APP_BIN에 설치한다(관리자 권한 불필요)."""
    APP_BIN.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(RCLONE_URL, timeout=120) as r:
        data = r.read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        member = next(n for n in z.namelist() if n.endswith("/rclone"))
        dest = APP_BIN / "rclone"
        dest.write_bytes(z.read(member))
    dest.chmod(0o755)
    return str(dest)
