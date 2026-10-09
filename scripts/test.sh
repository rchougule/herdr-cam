#!/bin/sh
# Runs every test that needs no herdr server or camera: the Swift core tests (as a
# test build and as a release build), the launcher tests, and headless runs of the
# real app bundles. The live suite is tests/e2e_live.sh (needs herdr + claude).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

swiftc -D HERDR_CAM_TESTING app/Core.swift tests/core/main.swift -o build/core-tests
build/core-tests "$root"
swiftc app/Core.swift tests/core/main.swift -o build/core-tests-release
build/core-tests-release "$root"

sh tests/cli_test.sh

# Test bundle: two fake photos through the real pipeline and result file.
sh scripts/build.sh build/test --testing
build/test/HerdrCam.app/Contents/MacOS/HerdrCam --out "$tmp/smoke" --max-edge 200 \
  --fake-image tests/fixtures/test.png --fake-image tests/fixtures/test.png
[ "$(head -n 1 "$tmp/smoke.result")" = ok ] || fail "smoke result: $(cat "$tmp/smoke.result")"
[ "$(sed -n 2p "$tmp/smoke.result")" = "$tmp/smoke-1.jpg" ] || fail "smoke result lists photo 1"
file "$tmp/smoke-2.jpg" | grep -q "JPEG image data" || fail "smoke photo 2 is not a JPEG"
echo "app: test bundle smoke run ok"

# Release bundle: same sources without the hooks. It must refuse them, and say so in
# the result file rather than only on stderr. Built in its own dir so the bundle the
# plugin uses (and its camera permission) is left alone.
sh scripts/build.sh build/test-release
codesign -dv build/test-release/HerdrCam.app 2>&1 | grep -q "flags=.*runtime" || fail "release bundle lacks hardened runtime"
/usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" build/test-release/HerdrCam.app/Contents/Info.plist >/dev/null ||
  fail "release bundle lacks NSCameraUsageDescription"
build/test-release/HerdrCam.app/Contents/MacOS/HerdrCam --out "$tmp/rel" --fake-image tests/fixtures/test.png 2>/dev/null &&
  fail "release bundle accepted --fake-image"
grep -q "unknown option --fake-image" "$tmp/rel.result" || fail "release bundle did not report the bad option"
echo "app: release bundle refuses test hooks ok"
