#!/usr/bin/env bash
# Builds build/Space.app: menu-bar app + spaced (run as a login-item LaunchAgent) + TailscaleKit + Sparkle.
#
# Environment (all optional; local builds need none):
#   VERSION         marketing version, e.g. 1.2.3                (default 0.1.0)
#   BUILD           integer build number, must grow every release (default 1)
#   FEED_URL        Sparkle appcast URL; without it the build has auto-update turned off
#   SU_PUBLIC_KEY   Sparkle EdDSA public key                      (default: Space's release key)
#   SIGN_IDENTITY   "Developer ID Application: …" to sign for distribution (default: ad-hoc "-")
#   SKIP_DAEMON_RESTART=1   don't stop the running daemon (CI)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
FEED_URL="${FEED_URL:-}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-DWv/Ifp6fQ7o3hXMJjES++JKv38ZVJQdve4T6WFCUNg=}"
SIGN="${SIGN_IDENTITY:--}"

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
cp Resources/AppIcon.icns "$C/Resources/AppIcon.icns"
cp -R "$(find Vendor/TailscaleKit.xcframework -maxdepth 2 -name TailscaleKit.framework | head -1)" "$C/Frameworks/"
cp -R "$BIN/Sparkle.framework" "$C/Frameworks/"
for exe in Space spaced; do
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/$exe" 2>/dev/null || true
done

FEED_KEYS=""
if [ -n "$FEED_URL" ]; then
  FEED_KEYS="
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>14400</integer>"
fi

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.space.Space</string>
  <key>CFBundleName</key><string>Space</string>
  <key>CFBundleDisplayName</key><string>Space</string>
  <key>CFBundleExecutable</key><string>Space</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local development services</string>$FEED_KEYS
</dict></plist>
PLIST

# Signing, inside out. Ad-hoc by default; with SIGN_IDENTITY (Developer ID) it uses the hardened runtime,
# which notarization requires.
sign() {
  if [ "$SIGN" = "-" ]; then codesign --force --sign - "$@"
  else codesign --force --timestamp --options runtime --sign "$SIGN" "$@"; fi
}
SPK="$C/Frameworks/Sparkle.framework/Versions/B"
for part in "$SPK"/XPCServices/*.xpc "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [ -e "$part" ] && sign "$part"
done
sign "$C/Frameworks/Sparkle.framework"
sign "$C/Frameworks/TailscaleKit.framework"
sign --identifier dev.space.spaced "$C/MacOS/spaced"
sign "$APP"
codesign --verify --deep --strict "$APP"

if [ -z "${SKIP_DAEMON_RESTART:-}" ]; then
  # Stop the running daemon (old binary); Space.app reloads its LaunchAgent with the new build on launch.
  launchctl bootout "gui/$(id -u)/dev.space.spaced" 2>/dev/null || true
fi
echo "Built $APP ($VERSION, build $BUILD, signed: $([ "$SIGN" = "-" ] && echo ad-hoc || echo "$SIGN"), updates: $([ -n "$FEED_URL" ] && echo on || echo off))"
