#!/bin/sh
# Assertions are eval strings, expanded when they run, hence the disables.
# shellcheck disable=SC2016,SC2034,SC2012
# Tests for bin/herdr-cam against a fake herdr socket, fake herdr CLI, and a fake
# `open`. No herdr server or camera needed; runs in CI. Never touches real user state.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cam="$root/bin/herdr-cam"
work="$(mktemp -d)"
sock_pid=""
trap '[ -n "$sock_pid" ] && kill "$sock_pid" 2>/dev/null; rm -rf "$work"' EXIT

pass=0
fail=0
expect() {
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL: $1"
  fi
}

# Hooks from the outer environment must not leak in.
unset HERDR_CAM_FAKE_IMAGES HERDR_CAM_AUTO_CAPTURE HERDR_CAM_AUTO_SHOTS HERDR_CAM_APP HERDR_PANE_ID

# Plugin-like environment, all of it inside $work.
export HERDR_SOCKET_PATH="$work/herdr.sock"
export HERDR_BIN_PATH="$root/tests/support/fake-herdr"
export HERDR_PLUGIN_STATE_DIR="$work/state"
export HERDR_PLUGIN_CONFIG_DIR="$work/config"
export HERDR_CONFIG_PATH="$work/herdr-config.toml"
export HERDR_CAM_APP="$work/HerdrCam.app"
export HERDR_CAM_OPEN="$root/tests/support/fake-open"
export HERDR_CAM_NO_DETACH=1
export HERDR_CAM_NO_REFOCUS=1
export FAKE_HERDR_LOG="$work/herdr.log"
export FAKE_OPEN_LOG="$work/open.log"
export FAKE_FIXTURE="$root/tests/fixtures/test.png"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR" "$HERDR_CAM_APP"
conf="$HERDR_PLUGIN_CONFIG_DIR/config.env"
cap="$HERDR_PLUGIN_STATE_DIR/captures"

python3 -I "$root/tests/support/fake_socket.py" "$HERDR_SOCKET_PATH" "$work/sock.log" "$work/sock.ready" &
sock_pid=$!
i=0
while [ ! -f "$work/sock.ready" ] && [ $i -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -f "$work/sock.ready" ] || {
  echo "FAIL: fake herdr socket never came up"
  exit 1
}

reset() {
  : >"$work/sock.log"
  : >"$work/herdr.log"
  : >"$work/open.log"
  rm -f "$conf"
  rm -rf "$HERDR_PLUGIN_STATE_DIR/lock"
}
# Runs a capture with extra VAR=value settings, keeping its exit code in $rc. Goes
# through `env` because `VAR=x some_function` leaks VAR into later tests in POSIX sh.
capture() {
  env "$@" "$cam" capture
  rc=$?
}
paths_in_paste() { grep -o '"text":"[^"]*"' "$work/sock.log"; }

# --- paste ----------------------------------------------------------------------------
reset
"$cam" paste "w1:p2" '/tmp/a "quoted" \ path.jpg' >/dev/null
expect "paste sends pane.send_input" 'grep -q "\"method\":\"pane.send_input\"" "$work/sock.log"'
expect "paste targets the pane" 'grep -q "\"pane_id\":\"w1:p2\"" "$work/sock.log"'
expect "paste JSON-escapes the text" 'grep -qF "\"text\":\"/tmp/a \\\"quoted\\\" \\\\ path.jpg\"" "$work/sock.log"'
expect "paste sends no Enter" '! grep -q "\"keys\"" "$work/sock.log"'
expect "paste request is valid JSON" 'python3 -I -c "import json,sys; json.loads(open(sys.argv[1]).readline())" "$work/sock.log"'
reset
"$cam" paste "w1:missing" /tmp/a.jpg >/dev/null 2>&1
expect "paste fails on a herdr error" '[ $? -ne 0 ]'

# --- capture: one photo -----------------------------------------------------------------
reset
capture HERDR_PANE_ID=w1:p2 FAKE_OPEN_MODE=ok
shot="$(ls "$cap"/note-*-1.jpg 2>/dev/null | head -1)"
expect "capture exits 0" '[ "$rc" -eq 0 ]'
expect "capture runs open -W on the app" 'grep -q -- "^-W $HERDR_CAM_APP --args --out $cap/note-" "$work/open.log"'
expect "fake open saw -W" '! grep -q "without -W" "$work/open.log"'
expect "photo saved in state/captures" '[ -s "$shot" ]'
expect "photo pasted into the focused pane" 'grep -qF "\"pane_id\":\"w1:p2\",\"text\":\"$shot\"" "$work/sock.log"'
expect "default settings passed" 'grep -q -- "--max-edge 2048 --quality 0.85 --timer 3" "$work/open.log"'
expect "result file cleaned up" '[ -z "$(ls "$cap"/*.result 2>/dev/null)" ]'
expect "lock released" '[ ! -d "$HERDR_PLUGIN_STATE_DIR/lock" ]'
expect "captures dir is private" '[ "$(stat -f %Lp "$cap")" = 700 ]'

# --- capture: several photos go in one paste, in order ---------------------------------
reset
capture HERDR_PANE_ID=w1:p2 FAKE_SHOTS=3 FAKE_OPEN_MODE=ok
expect "multi capture exits 0" '[ "$rc" -eq 0 ]'
expect "one paste for all photos" '[ "$(wc -l <"$work/sock.log" | tr -d " ")" = 1 ]'
expect "paths in order, space separated" 'paths_in_paste | grep -Eq "note-[^ ]*-1\.jpg [^ ]*-2\.jpg [^ ]*-3\.jpg\"$"'

# --- capture: focused pane comes from HERDR_PANE_ID, else `herdr pane current` ---------
reset
capture FAKE_OPEN_MODE=ok
expect "falls back to herdr pane current (real reply shape)" 'grep -q "\"pane_id\":\"w9:p9\"" "$work/sock.log"'

# --- capture: cancel, error, crash, open failure, paste failure -------------------------
reset
capture FAKE_OPEN_MODE=cancel
expect "cancel exits 0" '[ "$rc" -eq 0 ]'
expect "cancel pastes nothing" '[ ! -s "$work/sock.log" ]'
expect "cancel shows no notification" '! grep -q "notification" "$work/herdr.log"'

reset
capture FAKE_OPEN_MODE=error
expect "error exits 1" '[ "$rc" -eq 1 ]'
expect "error pastes nothing" '[ ! -s "$work/sock.log" ]'
expect "error message shown as a notification" 'grep -q "notification show herdr-cam --body Camera access is off for HerdrCam." "$work/herdr.log"'

reset
capture FAKE_OPEN_MODE=crash
expect "a crash (no result) exits 1" '[ "$rc" -eq 1 ]'
expect "a crash is reported, not taken for a cancel" 'grep -q "closed without taking a photo" "$work/herdr.log"'

reset
capture FAKE_OPEN_MODE=fail
expect "open failing exits 1" '[ "$rc" -eq 1 ]'
expect "open failing is reported" 'grep -q "Could not open HerdrCam" "$work/herdr.log"'

reset
capture HERDR_PANE_ID=w1:missing FAKE_OPEN_MODE=ok 2>/dev/null
expect "paste failure exits 1" '[ "$rc" -eq 1 ]'
expect "paste failure is reported with where the photos are" 'grep -q "could not paste into pane w1:missing" "$work/herdr.log"'

# --- capture: preconditions -------------------------------------------------------------
reset
capture HERDR_CAM_APP="$work/missing.app"
expect "unbuilt app exits 1" '[ "$rc" -eq 1 ]'
expect "unbuilt app is reported" 'grep -q "is not built" "$work/herdr.log"'
expect "unbuilt app never launches" '[ ! -s "$work/open.log" ]'

reset
capture HERDR_BIN_PATH=/usr/bin/true
expect "no focused pane exits 1" '[ "$rc" -eq 1 ]'
expect "no focused pane opens nothing" '[ ! -s "$work/open.log" ]'

# --- one window at a time ----------------------------------------------------------------
reset
mkdir -p "$HERDR_PLUGIN_STATE_DIR/lock"
sleep 30 &
holder=$!
echo "$holder" >"$HERDR_PLUGIN_STATE_DIR/lock/pid"
capture FAKE_OPEN_MODE=ok
expect "a live lock blocks a second window" '[ ! -s "$work/open.log" ]'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
capture FAKE_OPEN_MODE=ok
expect "a stale lock is taken over" '[ -s "$work/open.log" ]'

# --- settings: read as data, validated --------------------------------------------------
reset
printf 'MAX_EDGE=1024\r\nQUALITY="0.6"\r\n# comment\r\n\r\nTIMER = 5\r\n' >"$conf"
capture FAKE_OPEN_MODE=ok
expect "CRLF, quotes, comments and spaces are fine" 'grep -q -- "--max-edge 1024 --quality 0.6 --timer 5" "$work/open.log"'
expect "good config is not reported" '! grep -q "Ignoring config.env" "$work/herdr.log"'

reset
printf 'QUALITY=1.5\nTIMER=0\nMAX_EDGE=32\nNOPE=1\n' >"$conf"
capture FAKE_OPEN_MODE=ok
expect "bad values fall back to defaults" 'grep -q -- "--max-edge 2048 --quality 0.85 --timer 3" "$work/open.log"'
expect "bad values are reported" 'grep -q "Ignoring config.env: QUALITY=1.5 .*TIMER=0 .*MAX_EDGE=32 .*unknown setting .NOPE." "$work/herdr.log"'
expect "capture still works with a bad config" '[ "$rc" -eq 0 ] && [ -s "$work/sock.log" ]'

reset
printf 'TIMER=$(touch %s/pwned)\nKEEP_DAYS=`touch %s/pwned2`\n' "$work" "$work" >"$conf"
capture FAKE_OPEN_MODE=ok
expect "config.env is never executed" '[ ! -e "$work/pwned" ] && [ ! -e "$work/pwned2" ]'

reset
printf 'HERDR_CAM_FAKE_IMAGES=/x.png\nHERDR_CAM_AUTO_CAPTURE=1\n' >"$conf"
capture FAKE_OPEN_MODE=ok
expect "test hooks are ignored in config.env" '! grep -q -- "--fake-image\|--auto-capture" "$work/open.log"'

# --- test hooks from the environment ----------------------------------------------------
reset
capture HERDR_CAM_FAKE_IMAGES="/x/a.png:/x/b.png" HERDR_CAM_AUTO_CAPTURE=4 HERDR_CAM_AUTO_SHOTS=2 FAKE_OPEN_MODE=ok
expect "fake images forwarded in order" 'grep -q -- "--fake-image /x/a.png --fake-image /x/b.png" "$work/open.log"'
expect "auto capture forwarded" 'grep -q -- "--auto-capture 4 --auto-shots 2" "$work/open.log"'

# --- detached worker ----------------------------------------------------------------------
reset
HERDR_PANE_ID=w1:p2 FAKE_OPEN_MODE=ok HERDR_CAM_NO_DETACH="" "$cam" capture
rc=$?
i=0
while [ ! -s "$work/sock.log" ] && [ $i -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
sleep 0.3
expect "detached capture returns at once with 0" '[ "$rc" -eq 0 ]'
expect "detached worker pastes" 'grep -q "\"pane_id\":\"w1:p2\"" "$work/sock.log"'
expect "detached worker logs the capture" 'grep -q "captured 1 photo(s) -> pane w1:p2" "$HERDR_PLUGIN_STATE_DIR/herdr-cam.log"'
expect "log is private" '[ "$(stat -f %Lp "$HERDR_PLUGIN_STATE_DIR/herdr-cam.log")" = 600 ]'
expect "detached worker releases the lock" '[ ! -d "$HERDR_PLUGIN_STATE_DIR/lock" ]'

# --- prune ------------------------------------------------------------------------------------
reset
mkdir -p "$cap"
touch -t 202001010000 "$cap/note-old-1.jpg" "$cap/note-old.result"
touch "$cap/note-new-1.jpg" "$cap/keep-me.jpg"
printf 'KEEP_DAYS=7\n' >"$conf"
"$cam" prune
expect "prune drops old photos and results" '[ ! -e "$cap/note-old-1.jpg" ] && [ ! -e "$cap/note-old.result" ]'
expect "prune keeps recent photos" '[ -e "$cap/note-new-1.jpg" ]'
expect "prune only touches its own files" '[ -e "$cap/keep-me.jpg" ]'
printf 'KEEP_DAYS=0\n' >"$conf"
touch -t 202001010000 "$cap/note-old-1.jpg"
"$cam" prune
expect "KEEP_DAYS=0 keeps everything" '[ -e "$cap/note-old-1.jpg" ]'
reset
printf 'KEEP_DAYS=7\n' >"$conf"
capture FAKE_OPEN_MODE=cancel
expect "pruning runs on every capture, even a cancelled one" '[ ! -e "$cap/note-old-1.jpg" ]'

# --- doctor --------------------------------------------------------------------------------
reset
"$cam" doctor >"$work/doctor.out"
expect "doctor fails without a signed app" '[ $? -ne 0 ] && grep -q "FAIL  app" "$work/doctor.out"'
expect "doctor reports through a notification" 'grep -q "notification show herdr-cam --body doctor: 1 problem" "$work/herdr.log"'
reset
printf 'TIMER=99\n' >"$conf"
"$cam" doctor >"$work/doctor.out"
expect "doctor lists config problems" 'grep -q "WARN  config.env: TIMER=99" "$work/doctor.out"'
expect "doctor warns about a missing keybinding" 'grep -q "WARN  no keybinding" "$work/doctor.out"'

# --- usage ------------------------------------------------------------------------------------
"$cam" >/dev/null 2>&1
expect "no command exits 2" '[ $? -eq 2 ]'
"$cam" bogus >/dev/null 2>&1
expect "unknown command exits 2" '[ $? -eq 2 ]'

# --- manifest ---------------------------------------------------------------------------------
m="$root/herdr-plugin.toml"
expect "manifest declares capture action" 'grep -q "^id = \"capture\"" "$m"'
expect "manifest builds the app" 'grep -q "scripts/build.sh" "$m"'
expect "manifest action runs bin/herdr-cam capture" 'grep -q "\"bin/herdr-cam\", \"capture\"" "$m"'

echo "cli: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
