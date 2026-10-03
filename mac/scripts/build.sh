#!/bin/bash
# DJI2Note.app과 DMG를 만든다: mac/scripts/build.sh [버전]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 '^version' ../pyproject.toml | cut -d'"' -f2)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT=build
APP="$OUT/DJI2Note.app"
# 서명: 고정된 인증서로 서명해야 업데이트해도 macOS 권한(마이크·문서·이동식 볼륨)이 유지된다.
# SIGN_ID가 없으면 키체인의 Developer ID → Apple Development 순으로 찾고, 없으면 ad-hoc(매번 권한 다시 물음)
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
  [ -n "$SIGN_ID" ] || SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
  [ -n "$SIGN_ID" ] || SIGN_ID="-"
fi

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 컴파일 ($VERSION, build $BUILD)"
swift build -c release --arch arm64
cp .build/arm64-apple-macosx/release/DJI2Note "$APP/Contents/MacOS/DJI2Note"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# 볼륨 마운트 감지 에이전트(앱이 꺼져 있어도 DJI 연결 시 실행)
clang -O2 -arch arm64 -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/DJI2NoteMountHelper" Resources/mount-helper.c
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/io.dji2note.mount.plist "$APP/Contents/Library/LaunchAgents/"

echo "==> 아이콘"
ICONSET="$OUT/AppIcon.iconset"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$OUT/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 서명 ($SIGN_ID)"
codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$APP"

echo "==> DMG"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "DJI2Note" -srcfolder "$STAGE" -ov -format UDZO "$OUT/DJI2Note.dmg"
(cd "$OUT" && ditto -c -k --keepParent DJI2Note.app DJI2Note.zip)
rm -rf "$STAGE" "$ICONSET"

echo "완료: $APP"
ls -lh "$OUT"/DJI2Note.dmg "$OUT"/DJI2Note.zip
