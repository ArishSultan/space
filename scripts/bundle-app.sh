#!/usr/bin/env bash
# Builds build/Space.app: menu-bar app + spaced (run as a login-item LaunchAgent) + TailscaleKit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -d Vendor/TailscaleKit.xcframework ] || scripts/build-tailscalekit.sh

swift build -c release --product spaced
swift build -c release --product Space
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Space.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"

cp "$BIN/Space" "$C/MacOS/Space"
cp "$BIN/spaced" "$C/MacOS/spaced"
cp -R Sources/SpaceCore/Recipes "$C/Resources/Recipes"
cp -R "$(find Vendor/TailscaleKit.xcframework -maxdepth 2 -name TailscaleKit.framework | head -1)" "$C/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/spaced" 2>/dev/null || true

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.space.Space</string>
  <key>CFBundleName</key><string>Space</string>
  <key>CFBundleDisplayName</key><string>Space</string>
  <key>CFBundleExecutable</key><string>Space</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local development services</string>
</dict></plist>
PLIST


# Ad-hoc signature (no Developer ID needed for personal use). Sign inner code first.
codesign --force --sign - "$C/Frameworks/TailscaleKit.framework"
codesign --force --sign - --identifier dev.space.spaced "$C/MacOS/spaced"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Stop the running daemon (old binary); Space.app reloads its LaunchAgent with the new build on launch.
launchctl bootout "gui/$(id -u)/dev.space.spaced" 2>/dev/null || true
echo "Built $APP — open it to (re)start the background service"
