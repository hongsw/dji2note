#!/bin/bash
# DJI2Note Mac 앱 설치 (Apple Silicon)
#   curl -fsSL https://raw.githubusercontent.com/hongsw/dji2note/main/install-app.sh | bash
set -euo pipefail

URL="${DJI2NOTE_APP_URL:-https://github.com/hongsw/dji2note/releases/latest/download/DJI2Note.zip}"
say() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m오류:\033[0m %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS 전용입니다."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon(M1 이상) Mac이 필요합니다."

# 응용 프로그램/Baryon 폴더에 설치 (Baryon 앱 모음)
BASE=/Applications
[ -w "$BASE" ] || BASE="$HOME/Applications"
DEST="$BASE/Baryon"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "DJI2Note 내려받는 중…"
curl -fsSL "$URL" -o "$TMP/DJI2Note.zip"
ditto -x -k "$TMP/DJI2Note.zip" "$TMP"

pkill -x DJI2Note 2>/dev/null || true
rm -rf "$DEST/DJI2Note.app" "$BASE/DJI2Note.app"   # 이전 버전은 응용 프로그램 바로 아래에 있었음
mv "$TMP/DJI2Note.app" "$DEST/"
say "설치 완료: $DEST/DJI2Note.app"
open "$DEST/DJI2Note.app"
