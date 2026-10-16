#!/usr/bin/env bash
# Збирає CheckBatteryHealth.app у ./build
#   ./scripts/build_app.sh            — для архітектури цього Mac
#   UNIVERSAL=1 ./scripts/build_app.sh — universal (arm64 + x86_64, потрібен Xcode)
#   INSTALL=1 ./scripts/build_app.sh   — додатково скопіювати в /Applications
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CheckBatteryHealth"
ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc підпис — потрібен, щоб macOS показала запит на доступ до Bluetooth.
codesign --force --sign - "$APP"

echo "Готово: $APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    echo "Встановлено в /Applications/${APP_NAME}.app"
fi
