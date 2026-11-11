#!/usr/bin/env bash
# Packages build/Space.app (from scripts/bundle-app.sh) into build/Space-<version>.zip, optionally notarizes it,
# and writes the signed Sparkle appcast build/appcast.xml.
#
# Environment:
#   VERSION, BUILD         same values the app was built with (required)
#   REPO                   GitHub "owner/name" the release is published to (required)
#   SPARKLE_PRIVATE_KEY    EdDSA private key (contents of the exported key file). Without it the key named
#                          SPARKLE_ACCOUNT (default space-app) is read from the login keychain.
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD   optional: notarize + staple (needs a Developer ID build)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${VERSION:?}" "${BUILD:?}" "${REPO:?}"
APP="build/Space.app"
ZIP="build/Space-$VERSION.zip"
TAG="v$VERSION"
TOOLS="$(find .build/artifacts -type d -path '*sparkle/Sparkle/bin' | head -1)"
[ -x "$TOOLS/sign_update" ] || { echo "Sparkle tools not found; run 'swift package resolve' first" >&2; exit 1; }

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_APPLE_ID:-}" ]; then
  echo "Notarizing…"
  xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" --team-id "${NOTARY_TEAM_ID:?}" \
    --password "${NOTARY_PASSWORD:?}" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - "$ZIP")"
else
  SIGNATURE="$("$TOOLS/sign_update" --account "${SPARKLE_ACCOUNT:-space-app}" "$ZIP")"
fi
# → sparkle:edSignature="…" length="…"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Space</title>
    <item>
      <title>Space $VERSION</title>
      <pubDate>$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Space-$VERSION.zip"
                 $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "Packaged $ZIP and build/appcast.xml"
