"""설정 파일(~/.config/dji2note/config.toml)과 상태 파일 관리."""
import json
import os
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("DJI2NOTE_HOME", Path.home() / ".config" / "dji2note"))
CONFIG_FILE = CONFIG_DIR / "config.toml"
STATE_FILE = CONFIG_DIR / "state.json"
LOCK_FILE = CONFIG_DIR / "run.lock"
RUN_FILE = CONFIG_DIR / "running.json"
LOG_FILE = Path.home() / "Library" / "Logs" / "dji2note.log"


@dataclass
class Config:
    output_dir: str = str(Path.home() / "dji2note")
    language: str = "ko"
    whisper_model: str = "mlx-community/whisper-large-v3-turbo"
    # llm_backend: claude-cli | codex-cli | anthropic-api | openai-api | gemini-api | baryon | none
    llm_backend: str = "none"
    llm_model: str = "claude-sonnet-5"          # 요약
    llm_fast_model: str = "claude-sonnet-5"     # 대본 교정(출력이 길어 빠른 모델) — 비우면 llm_model 사용
    llm_parallel: int = 4                       # 대본 조각 동시 처리 수
    default_situation: str = "auto"             # DJI·음성 메모의 녹음 상황 (auto = AI가 판별)
    low_power: bool = False                     # 저전력: 우선순위 낮춤 + AI 동시 처리 2개로
    anthropic_api_key: str = ""
    openai_api_key: str = ""
    gemini_api_key: str = ""
    baryon_api_url: str = ""                    # Anthropic 호환 Messages API 주소
    baryon_api_key: str = ""
    # upload: "none" | "rclone"
    upload: str = "none"
    rclone_remote: str = "gdrive"
    drive_folder: str = "dji2note"
    notion_enabled: bool = False
    notion_token: str = ""                      # Notion 내부 통합 토큰 (ntn_… / secret_…)
    notion_parent: str = ""                     # 회의록을 모을 페이지·데이터베이스 링크
    notify: bool = True
    extra: dict = field(default_factory=dict)

    @property
    def notes_dir(self) -> Path:
        return Path(self.output_dir).expanduser() / "notes"

    @property
    def recordings_dir(self) -> Path:
        return Path(self.output_dir).expanduser() / "recordings"


def load() -> Config:
    if not CONFIG_FILE.exists():
        return Config()
    data = tomllib.loads(CONFIG_FILE.read_text())
    known = {k: v for k, v in data.items() if k in Config.__dataclass_fields__}
    return Config(**known)


def _toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return json.dumps(str(v), ensure_ascii=False)


def save(cfg: Config):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    lines = ["# dji2note 설정 — `dji2note init`으로 다시 만들 수 있습니다"]
    for k, v in asdict(cfg).items():
        if k != "extra":
            lines.append(f"{k} = {_toml_value(v)}")
    CONFIG_FILE.write_text("\n".join(lines) + "\n")
    CONFIG_FILE.chmod(0o600)  # API 키가 들어갈 수 있음


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1))
    tmp.replace(STATE_FILE)
