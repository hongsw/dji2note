"""launchd 에이전트: 볼륨이 마운트될 때마다 `dji2note run` 실행."""
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from .config import LOG_FILE
from .tools import APP_BIN

LABEL = "io.dji2note.agent"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def _domain():
    return f"gui/{os.getuid()}"


def executable() -> str:
    exe = shutil.which("dji2note")
    return exe or str(Path(sys.argv[0]).resolve())


def install():
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    path = ":".join([str(APP_BIN), str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    plist = {
        "Label": LABEL,
        "ProgramArguments": [executable(), "run"],
        "StartOnMount": True,
        "EnvironmentVariables": {"PATH": path, "PYTHONUNBUFFERED": "1"},
        "StandardOutPath": str(LOG_FILE),
        "StandardErrorPath": str(LOG_FILE),
        "ProcessType": "Background",
    }
    subprocess.run(["launchctl", "bootout", f"{_domain()}/{LABEL}"], capture_output=True)
    PLIST.write_bytes(plistlib.dumps(plist))
    subprocess.run(["launchctl", "bootstrap", _domain(), str(PLIST)], check=True)


def uninstall():
    subprocess.run(["launchctl", "bootout", f"{_domain()}/{LABEL}"], capture_output=True)
    PLIST.unlink(missing_ok=True)


def status() -> str:
    if not PLIST.exists():
        return "설치 안 됨"
    out = subprocess.run(["launchctl", "print", f"{_domain()}/{LABEL}"], capture_output=True, text=True)
    if out.returncode != 0:
        return "plist는 있으나 로드 안 됨 (dji2note service install 로 다시 설치)"
    runs = next((l.split("=")[1].strip() for l in out.stdout.splitlines() if l.strip().startswith("runs")), "?")
    return f"동작 중 (DJI 연결 시 자동 실행, 지금까지 {runs}회 실행)"
