#!/bin/bash
set -euo pipefail
# Example: SIMULATOR_UDID=<simulator-udid> "$0" /external/output-directory

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /external/output-directory" >&2
  exit 2
fi
WORK="$1"
DEVICE="${SIMULATOR_UDID:-}"
SIMCTL=(xcrun simctl)
if [[ -n "${SIMULATOR_DEVICE_SET:-}" ]]; then
  mkdir -p "$SIMULATOR_DEVICE_SET"
  SIMCTL=(xcrun simctl --set "$SIMULATOR_DEVICE_SET")
fi
if [[ -z "$DEVICE" ]]; then
  echo "Set SIMULATOR_UDID to an existing iOS 26.0+ simulator UDID." >&2
  exit 2
fi
BUNDLE='org.nxnative.ioslookharness'
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
APP="$WORK/IOSLookHarness.app"
HOST="$ROOT/dm/host"
PROFILE='01007EF00011E000'
WAS_BOOTED=0
INSTALLED=0
OWNER_MARKER="$WORK/.ios-look-harness-owned"

mkdir -p "$WORK"
if [[ -e "$APP" && ! -f "$OWNER_MARKER" ]]; then
  echo "Refusing to replace unowned app bundle: $APP" >&2
  exit 2
fi
rm -rf "$APP"
mkdir -p "$APP"
touch "$OWNER_MARKER"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>IOSLookHarness</string>
  <key>CFBundleIdentifier</key><string>org.nxnative.ioslookharness</string>
  <key>CFBundleName</key><string>IOSLookHarness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UISupportedInterfaceOrientations</key><array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
</dict></plist>
PLIST

make -s -C "$HOST" GAME="$PROFILE" game_profile
mkdir -p "$APP/dm"
cp "$ROOT/dm/games/$PROFILE"/touch_*.png "$APP/dm/"
xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios26.0-simulator -isysroot "$SDK" -fobjc-arc -fblocks -O1 -g -DDM_TEST_HOOKS \
  -I"$HOST" -I"$HOST/gen/$PROFILE" -I"$ROOT/dm/games/$PROFILE" \
  "$ROOT/dm/ios/tests/ios_look_harness.m" "$ROOT/dm/ios/Sources/DmGamepad.m" \
  -framework UIKit -framework GameController -framework CoreMotion -framework CoreText -framework QuartzCore -framework CoreGraphics \
  -o "$APP/IOSLookHarness"
plutil -lint "$APP/Info.plist"
codesign --force --deep --sign - "$APP"

if "${SIMCTL[@]}" list devices | grep -F "$DEVICE" | grep -q '(Booted)'; then
  WAS_BOOTED=1
else
  "${SIMCTL[@]}" boot "$DEVICE"
fi
cleanup() {
  if [[ "$INSTALLED" == 1 ]]; then
    "${SIMCTL[@]}" terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    "${SIMCTL[@]}" uninstall "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  fi
  if [[ "$WAS_BOOTED" == 0 ]]; then "${SIMCTL[@]}" shutdown "$DEVICE" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
"${SIMCTL[@]}" bootstatus "$DEVICE" -b
"${SIMCTL[@]}" install "$DEVICE" "$APP"
INSTALLED=1
DATA="$("${SIMCTL[@]}" get_app_container "$DEVICE" "$BUNDLE" data)"
rm -f "$DATA/Documents/result.txt" "$DATA/Documents/details.log"
"${SIMCTL[@]}" launch --terminate-running-process "$DEVICE" "$BUNDLE"
for _ in $(seq 1 120); do
  [[ -f "$DATA/Documents/result.txt" ]] && break
  sleep 0.25
done
if [[ ! -f "$DATA/Documents/result.txt" ]]; then
  echo "Harness did not finish; simulator app container: $DATA" >&2
  exit 1
fi
cp "$DATA/Documents/result.txt" "$WORK/run.log"
cp "$DATA/Documents/details.log" "$WORK/details.log"
cp "$DATA/Documents/botw-buttons.png" "$WORK/botw-buttons.png"
cp "$DATA/Documents/botw-portrait.png" "$WORK/botw-portrait.png"
cp "$DATA/Documents/botw-dpad-fallback.png" "$WORK/botw-dpad-fallback.png"
cp "$DATA/Documents/botw-shield-drag.png" "$WORK/botw-shield-drag.png"
cp "$DATA/Documents/botw-left-drag.png" "$WORK/botw-left-drag.png"
cat "$WORK/run.log"
grep -F 'UIKit handler regression: 0 failures;' "$WORK/run.log"
