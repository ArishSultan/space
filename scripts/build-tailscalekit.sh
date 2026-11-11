#!/usr/bin/env bash
# Builds Tailscale's official TailscaleKit (libtailscale/swift) into Vendor/TailscaleKit.xcframework.
# Build-time only requirements: Xcode and Go (`brew install go`). End users need neither.
set -euo pipefail

REV="dacde75057ff350e146505829beff446e6823966"   # tailscale/libtailscale, pinned
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v go >/dev/null || { echo "Go is required to build TailscaleKit: brew install go" >&2; exit 1; }

git clone -q https://github.com/tailscale/libtailscale.git "$WORK/libtailscale"
git -C "$WORK/libtailscale" checkout -q "$REV"
make -C "$WORK/libtailscale/swift" macos >"$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; exit 1; }

rm -rf "$ROOT/Vendor/TailscaleKit.xcframework"
xcodebuild -create-xcframework \
  -framework "$WORK/libtailscale/swift/build/Build/Products/Release/TailscaleKit.framework" \
  -output "$ROOT/Vendor/TailscaleKit.xcframework" >/dev/null
echo "Built Vendor/TailscaleKit.xcframework (libtailscale @ ${REV:0:12})"
