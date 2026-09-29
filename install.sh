#!/bin/bash
# dji2note 설치 스크립트 (Apple Silicon Mac)
#   curl -fsSL https://raw.githubusercontent.com/hongsw/dji2note/main/install.sh | bash
set -euo pipefail

REPO="${DJI2NOTE_REPO:-https://github.com/hongsw/dji2note/archive/refs/heads/main.zip}"
say() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m오류:\033[0m %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS 전용입니다."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon(M1 이상) Mac이 필요합니다."

# uv (Python 도구 설치기)
if ! command -v uv >/dev/null 2>&1; then
  say "uv 설치"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

say "dji2note 설치"
uv tool install --force --python 3.12 "$REPO"
uv tool update-shell >/dev/null 2>&1 || true
export PATH="$HOME/.local/bin:$PATH"

say "ffmpeg·rclone 준비 (Homebrew 불필요)"
dji2note setup-tools

say "설치 완료. 설정 마법사를 시작합니다."
dji2note init </dev/tty
