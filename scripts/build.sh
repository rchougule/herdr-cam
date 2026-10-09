#!/bin/sh
# Builds HerdrCam.app from app/*.swift.
#
#   scripts/build.sh                  build/HerdrCam.app, the plugin's [[build]] step
#   scripts/build.sh DIR --testing    DIR/HerdrCam.app with the test hooks compiled in
#
# Needs the Xcode Command Line Tools 15+ (`xcode-select --install`).
#
# The bundle is ad-hoc signed with the hardened runtime (so nothing can inject code
# into the app that holds the camera permission), and macOS ties the camera grant to
# that exact signature: every rebuild means one more "allow camera" prompt. Hence the
# build is skipped when the bundle is newer than every source, and test builds go to
# their own directory.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app="${1:-build}/HerdrCam.app"
testing="${2:-}"
bin="$app/Contents/MacOS/HerdrCam"
if [ -x "$bin" ] && [ -z "$(find app scripts/build.sh -newer "$bin" -type f)" ]; then
  echo "up to date $root/$app"
  exit 0
fi

# Native arch even from a Rosetta shell, where `uname -m` would say x86_64.
arch=x86_64
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && arch=arm64

flags=""
[ "$testing" = "--testing" ] && flags="-D HERDR_CAM_TESTING"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp app/Info.plist "$app/Contents/Info.plist"

# shellcheck disable=SC2086 # $flags is intentionally split
swiftc -O -parse-as-library $flags \
  -target "$arch-apple-macos14.0" \
  -framework AppKit -framework AVFoundation \
  app/Core.swift app/CamApp.swift \
  -o "$bin"

codesign --force --sign - --options runtime --entitlements app/HerdrCam.entitlements "$app"
echo "built $root/$app ($arch${testing:+, test hooks})"
