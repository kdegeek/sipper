#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP_NAME='Sipper BH71 Test'
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
BUILD_DIR="$ROOT_DIR/build/bh71"
case "$MODE" in run|--build-only|--verify|--logs|--telemetry|--debug) ;; *) exit 2;; esac
# Never stop or overwrite the installed Sipper app.
if [ "$MODE" != '--build-only' ]; then pkill -x "$APP_NAME" 2>/dev/null || true; fi
mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
if [ ! -f vendor/pjsip/lib/libpjproject.a ]; then scripts/build-pjsip.sh > "$BUILD_DIR/pjsip.log" 2>&1; fi
SDK_PATH="${SIPPER_SDK_PATH:-$(xcrun --show-sdk-path)}"
# CLT 27 does not ship the SwiftUI State macro plugin. Use the installed
# stable SDK when available; no changes to global xcode-select settings.
if [ -z "${SIPPER_SDK_PATH:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
xcrun clang -c Sipper/SIP/Bridging/pjsua_shim.c -I vendor/pjsip/include -DPJ_AUTOCONF=1 \
  -target arm64-apple-macos14.0 -isysroot "$SDK_PATH" -o "$BUILD_DIR/pjsua_shim.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files Sipper -g '*.swift' | sort)
xcrun swiftc -swift-version 5 -D SIPPER_BH71_TEST -module-name Sipper -O -g \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -import-objc-header Sipper/SIP/Bridging/Sipper-Bridging-Header.h \
  -I vendor/pjsip/include -Xcc -DPJ_AUTOCONF=1 -L vendor/pjsip/lib -lpjproject -lc++ \
  -framework IOKit -framework CoreAudio -framework CoreServices -framework AudioUnit \
  -framework AudioToolbox -framework Foundation -framework AppKit -framework Security \
  "${SOURCES[@]}" "$BUILD_DIR/pjsua_shim.o" -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
python3 - "$APP_BUNDLE" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]);p=plistlib.loads(Path('Sipper/Info.plist').read_bytes())
p.update(CFBundleExecutable='Sipper BH71 Test',CFBundleName='Sipper BH71 Test',CFBundleDisplayName='Sipper BH71 Test',CFBundleIdentifier='com.hybes.sipper.bh71test',CFBundleShortVersionString='0.1.0-bh71',CFBundleVersion='1',CFBundleDevelopmentRegion='en',LSMinimumSystemVersion='14.0',CFBundleIconFile='AppIcon')
# Do not compete with the installed app for sip:, tel:, or sipper: links.
p.pop('CFBundleURLTypes',None)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(p))
PY
mkdir -p "$BUILD_DIR/AppIcon.iconset"
cp Sipper/Resources/Assets.xcassets/AppIcon.appiconset/*.png "$BUILD_DIR/AppIcon.iconset/"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
tools/copy-licences.sh "$APP_BUNDLE/Contents/Resources/Licenses"
# Remove legacy Intel components when rebuilding an existing output bundle.
rm -f "$APP_BUNDLE/Contents/Helpers/YealinkBridge" "$APP_BUNDLE/Contents/Helpers/libyealinkusbsdk.dylib" "$APP_BUNDLE/Contents/Resources/Licenses/Yealink-SDK-README.md"
./script/build_native_helper.sh "$APP_BUNDLE/Contents/Helpers" "$SDK_PATH"
codesign --force --sign - --entitlements Sipper/Sipper.entitlements --options runtime "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Sipper BH71 Test"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" ;;
  *) open -n "$APP_BUNDLE" ;;
esac
