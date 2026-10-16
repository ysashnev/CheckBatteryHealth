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

# У SDK macOS 27 @State у SwiftUI — макрос, а Command Line Tools (без Xcode) не
# містять його плагіна SwiftUIMacros. Тоді беремо новітній SDK без цього макросу.
uses_state_macro() {
    grep -q 'public macro State()' \
        "$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/"*-apple-macos.swiftinterface \
        2>/dev/null
}
if [[ -z "${SDKROOT:-}" ]]; then
    PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins"
    DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    if [[ ! -e "$PLUGINS/libSwiftUIMacros.dylib" ]] && uses_state_macro "$DEFAULT_SDK"; then
        for sdk in $(ls -d "$(dirname "$DEFAULT_SDK")"/MacOSX[0-9]*.sdk | sort -rV); do
            if ! uses_state_macro "$sdk"; then
                export SDKROOT="$sdk"
                echo "Використовую сумісний SDK: $SDKROOT"
                break
            fi
        done
    fi
fi

swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Підпис потрібен, щоб macOS показала запит на доступ до Bluetooth. Якщо в Keychain
# є сертифікат "CheckBatteryHealth Local Signing", підписуємо ним: тоді дозвіл на
# Bluetooth зберігається між збірками. Інакше — ad-hoc (дозвіл скидається щоразу).
SIGN_IDENTITY="${SIGN_IDENTITY:-CheckBatteryHealth Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Готово: $APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    echo "Встановлено в /Applications/${APP_NAME}.app"
fi
