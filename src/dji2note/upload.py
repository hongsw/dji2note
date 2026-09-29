"""결과를 Google Drive에 Google Docs로 업로드 (rclone 사용)."""
import shutil
import subprocess
import tempfile
from pathlib import Path

from .config import Config

DOC_NAMES = {"summary.md": "요약", "transcript.md": "스크립트(화자분리)"}

HTML_TEMPLATE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>table{{border-collapse:collapse}}td,th{{border:1px solid #999;padding:4px 8px}}</style>
</head><body>{body}</body></html>"""


def rclone_path():
    return shutil.which("rclone")


def md_to_html(md_text: str, title: str) -> str:
    import markdown
    body = markdown.markdown(md_text, extensions=["tables", "sane_lists"])
    return HTML_TEMPLATE.format(title=title, body=body)


def drive_remotes() -> list[str]:
    rc = rclone_path()
    if not rc:
        return []
    out = subprocess.run([rc, "listremotes", "--long"], capture_output=True, text=True)
    return [line.split(":")[0] for line in out.stdout.splitlines() if line.split(":")[-1].strip() == "drive"]


def upload(cfg: Config, folder: Path) -> str:
    rc = rclone_path()
    if not rc:
        raise RuntimeError("rclone이 설치되어 있지 않습니다 (dji2note setup-tools)")
    dest = f"{cfg.rclone_remote}:{cfg.drive_folder}/{folder.name}"
    with tempfile.TemporaryDirectory() as tmp:
        for md, name in DOC_NAMES.items():
            src = folder / md
            if src.exists():
                (Path(tmp) / f"{name}.html").write_text(md_to_html(src.read_text(), name))
        # HTML을 Google Docs 문서로 변환해서 저장 (import·export 형식이 같아야 rclone이 변환함)
        out = subprocess.run([rc, "copy", tmp, dest, "--drive-import-formats", "html",
                              "--drive-export-formats", "html"], capture_output=True, text=True)
        if out.returncode != 0:
            raise RuntimeError(f"Drive 업로드 실패: {out.stderr.strip()[-400:]}")
    return dest
