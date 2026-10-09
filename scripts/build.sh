#!/bin/sh
# Builds HerdrCam.app from app/*.swift into build/ (or the directory given as $1).
# Runs as the plugin's [[build]] step on `herdr plugin install`, and by hand for local
# development. Needs the Xcode Command Line Tools (`xcode-select --install`).
#
# The bundle is ad-hoc signed, and macOS ties the camera grant to that exact signature,
# so every rebuild means one more "allow camera" prompt. Hence: skip the build when the
# bundle is already newer than every source, and keep test builds in their own dir.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app="${1:-build}/HerdrCam.app"
bin="$app/Contents/MacOS/HerdrCam"
if [ -x "$bin" ] && [ -z "$(find app -newer "$bin" -type f)" ]; then
  echo "up to date $root/$app"
  exit 0
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp app/Info.plist "$app/Contents/Info.plist"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework AVFoundation \
  app/Core.swift app/CamApp.swift \
  -o "$bin"

# Ad-hoc signature: macOS only offers the camera prompt to a signed bundle.
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $root/$app"
