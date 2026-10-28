#!/bin/sh
# builds build/reawm.app. signs with the first apple development identity so
# accessibility access survives rebuilds (ad-hoc signing resets it every time).
set -e
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | head -1)}"
export DEVELOPER_DIR
swift build -c release
app=build/reawm.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/reawm "$app/Contents/MacOS/reawm"
# the liquid glass icon for macOS 26 and later, plus an .icns for older systems.
# absolute paths: actool hands off to a daemon that has its own working directory
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$PWD/.build/icon.plist" >/dev/null
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>reawm</string>
  <key>CFBundleIdentifier</key><string>com.jxherc.reawm</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleName</key><string>reawm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>reawm commands</string>
    <key>CFBundleURLSchemes</key><array><string>reawm</string></array>
  </dict></array>
</dict>
</plist>
PLIST
id=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')
# the keychain can refuse from a non-interactive shell; fall back to ad-hoc
if [ -n "$id" ] && codesign --force --options runtime --sign "$id" "$app" 2>/dev/null; then
  echo "built $app (signed: $id)"
else
  codesign --force --sign - "$app"
  echo "built $app (ad-hoc signed: accessibility access must be re-granted after each rebuild)"
fi
