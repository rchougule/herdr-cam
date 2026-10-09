#!/bin/sh
# Assertions are eval strings, expanded when they run, hence the disables.
# shellcheck disable=SC2016,SC2034,SC2012
# Tests for bin/herdr-cam against a fake herdr socket, fake herdr CLI, and fake
# camera launcher. No herdr server or camera needed; runs in CI.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cam="$root/bin/herdr-cam"
work="$(mktemp -d)"
trap 'kill "$sock_pid" 2>/dev/null; rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL: $1"
}
expect() { if eval "$2"; then ok; else bad "$1"; fi; }

# Plugin-like environment.
export HERDR_SOCKET_PATH="$work/herdr.sock"
export HERDR_BIN_PATH="$root/tests/support/fake-herdr"
export HERDR_PLUGIN_STATE_DIR="$work/state"
export HERDR_PLUGIN_CONFIG_DIR="$work/config"
export HERDR_PANE_ID="w1:p2"
export HERDR_CAM_OPEN="$root/tests/support/fake-open"
export HERDR_CAM_NO_DETACH=1
export HERDR_CAM_NO_REFOCUS=1
export FAKE_HERDR_LOG="$work/herdr.log"
export FAKE_OPEN_LOG="$work/open.log"
export FAKE_FIXTURE="$root/tests/fixtures/test.png"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"

python3 -I "$root/tests/support/fake_socket.py" "$HERDR_SOCKET_PATH" "$work/sock.log" &
sock_pid=$!
i=0
while [ ! -S "$HERDR_SOCKET_PATH" ] && [ $i -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done

reset() { : >"$work/sock.log" && : >"$work/herdr.log" && : >"$work/open.log"; }

# --- paste: bracketed-paste request shape ---------------------------------------
reset
"$cam" paste "w1:p2" '/tmp/a "quoted" \ path.jpg' >/dev/null
expect "paste sends pane.send_input" 'grep -q "\"method\":\"pane.send_input\"" "$work/sock.log"'
expect "paste targets the pane" 'grep -q "\"pane_id\":\"w1:p2\"" "$work/sock.log"'
expect "paste JSON-escapes the path" 'grep -qF "\"text\":\"/tmp/a \\\"quoted\\\" \\\\ path.jpg\"" "$work/sock.log"'
expect "paste sends no Enter" '! grep -q "\"keys\"" "$work/sock.log"'
expect "paste request is valid JSON" 'python3 -I -c "import json,sys; json.loads(open(sys.argv[1]).readline())" "$work/sock.log"'

reset
"$cam" paste "w1:missing" /tmp/a.jpg >/dev/null 2>&1
expect "paste fails on herdr error" '[ $? -ne 0 ]'

# --- capture: happy path ---------------------------------------------------------
reset
FAKE_OPEN_MODE=ok "$cam" capture
shot="$(ls "$HERDR_PLUGIN_STATE_DIR"/captures/note-*.jpg 2>/dev/null | head -1)"
expect "capture saves into state/captures" '[ -s "$shot" ]'
expect "capture launches the app with --out" 'grep -q -- "HerdrCam.app --args --out $shot" "$work/open.log"'
expect "capture pastes the saved path into the focused pane" 'grep -qF "\"pane_id\":\"w1:p2\",\"text\":\"$shot\"" "$work/sock.log"'
expect "capture passes default max edge" 'grep -q -- "--max-edge 2048" "$work/open.log"'

# --- capture: config file overrides ---------------------------------------------
reset
printf 'MAX_EDGE=1024\nQUALITY=0.6\nTIMER=5\n' >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
FAKE_OPEN_MODE=ok "$cam" capture
expect "config MAX_EDGE honoured" 'grep -q -- "--max-edge 1024" "$work/open.log"'
expect "config QUALITY honoured" 'grep -q -- "--quality 0.6" "$work/open.log"'
expect "config TIMER honoured" 'grep -q -- "--timer 5" "$work/open.log"'
rm "$HERDR_PLUGIN_CONFIG_DIR/config.env"

# --- capture: falls back to `herdr pane current` without HERDR_PANE_ID ----------
reset
HERDR_PANE_ID="" FAKE_OPEN_MODE=ok "$cam" capture
expect "pane falls back to herdr pane current" 'grep -q "\"pane_id\":\"w9:p9\"" "$work/sock.log"'

# --- capture: cancel pastes nothing ---------------------------------------------
reset
FAKE_OPEN_MODE=cancel "$cam" capture
expect "cancel sends nothing" '[ ! -s "$work/sock.log" ]'
expect "cancel shows no notification" '! grep -q "notification" "$work/herdr.log"'

# --- capture: app error surfaces as a herdr notification ------------------------
reset
FAKE_OPEN_MODE=error "$cam" capture
expect "error sends nothing" '[ ! -s "$work/sock.log" ]'
expect "error shows a notification" 'grep -q "notification show herdr-cam --body Camera access denied." "$work/herdr.log"'
expect "error sidecar is cleaned up" '[ -z "$(ls "$HERDR_PLUGIN_STATE_DIR"/captures/*.err 2>/dev/null)" ]'

# --- capture: fake image is forwarded for live e2e runs --------------------------
reset
HERDR_CAM_FAKE_IMAGE=/x/y.png FAKE_OPEN_MODE=ok "$cam" capture
expect "fake image forwarded to the app" 'grep -q -- "--fake-image /x/y.png" "$work/open.log"'

# --- capture: auto-capture is forwarded for live camera e2e runs ----------------
reset
HERDR_CAM_AUTO_CAPTURE=4 FAKE_OPEN_MODE=ok "$cam" capture
expect "auto capture forwarded to the app" 'grep -q -- "--auto-capture 4" "$work/open.log"'

# --- prune ------------------------------------------------------------------------
reset
cap="$HERDR_PLUGIN_STATE_DIR/captures"
touch -t 202001010000 "$cap/note-old.jpg"
touch "$cap/note-new.jpg"
printf 'KEEP_DAYS=7\n' >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
"$cam" prune
expect "prune drops old captures" '[ ! -e "$cap/note-old.jpg" ]'
expect "prune keeps recent captures" '[ -e "$cap/note-new.jpg" ]'
printf 'KEEP_DAYS=0\n' >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
touch -t 202001010000 "$cap/note-old.jpg"
"$cam" prune
expect "KEEP_DAYS=0 keeps everything" '[ -e "$cap/note-old.jpg" ]'
rm "$HERDR_PLUGIN_CONFIG_DIR/config.env"

# --- unknown command ---------------------------------------------------------------
"$cam" bogus >/dev/null 2>&1
expect "unknown command exits non-zero" '[ $? -ne 0 ]'

# --- manifest ----------------------------------------------------------------------
m="$root/herdr-plugin.toml"
expect "manifest declares capture action" 'grep -q "^id = \"capture\"" "$m"'
expect "manifest builds the app" 'grep -q "scripts/build.sh" "$m"'
expect "manifest action runs bin/herdr-cam capture" 'grep -q "\"bin/herdr-cam\", \"capture\"" "$m"'

echo "cli: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
