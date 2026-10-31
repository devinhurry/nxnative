#!/bin/bash
# Build only; install this disposable app on a simulator for launcher UI checks.
set -euo pipefail
if [[ $# -ne 1 ]]; then echo "Usage: $0 /external/output-directory" >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$1"
APP="$WORK/BOTWLauncherTest.app"
mkdir -p "$APP/dm" "$WORK/metadata"
cp -R "$ROOT/dm/ios/Sources/"*.lproj "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BOTWLauncherTest</string>
<key>CFBundleIdentifier</key><string>org.nxnative.botwlaunchertest</string>
<key>CFBundleDisplayName</key><string>BOTW Settings Test</string>
<key>CFBundleName</key><string>BOTWLauncherTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
GFXAPI=nvn python3 "$ROOT/dm/games/settings.py" 01007EF00011E000 "$WORK/metadata" "$WORK/control.nacp" "$APP/dm/launcher.json"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator -isysroot "$SDK" -fobjc-arc \
    -c "$ROOT/dm/ios/Sources/CloudSaves.m" -o "$WORK/CloudSaves.o"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -target arm64-apple-ios26.0-simulator \
    -sdk "$SDK" -I "$ROOT/dm/host" -module-cache-path "$WORK/module-cache" -o "$APP/BOTWLauncherTest" \
    -import-objc-header "$ROOT/dm/ios/Sources/CloudSaves.h" "$WORK/CloudSaves.o" \
    "$ROOT/dm/ios/Sources/LauncherRow.swift" "$ROOT/dm/ios/Sources/LauncherSettings.swift" "$ROOT/dm/ios/Sources/BotwTouchSettings.swift" "$ROOT/dm/ios/Sources/Launcher.swift" "$ROOT/dm/ios/tests/launcher_ui_harness.swift"
plutil -lint "$APP/Info.plist"
codesign --force --sign - "$APP"
echo "Simulator app: $APP"
