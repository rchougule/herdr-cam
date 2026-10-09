#!/bin/sh
# Runs every test that needs no herdr server or camera: the Swift core tests, the
# launcher tests, and an app build plus a headless run of the real bundle.
# The live suite is tests/e2e_live.sh (needs herdr + claude).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build

swiftc app/Core.swift tests/core/main.swift -o build/core-tests
build/core-tests "$root"

sh tests/cli_test.sh

# Separate bundle, so a test run never re-signs the app the plugin uses.
sh scripts/build.sh build/test
out="$(mktemp -d)/smoke.jpg"
build/test/HerdrCam.app/Contents/MacOS/HerdrCam --out "$out" --fake-image tests/fixtures/test.png --max-edge 200
file "$out" | grep -q "JPEG image data" && echo "app: headless smoke run ok"
