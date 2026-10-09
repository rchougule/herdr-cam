#!/bin/sh
# Live end-to-end test. Needs a running herdr and the `claude` CLI. Not run in CI.
#
#   sh tests/e2e_live.sh            fixture mode: two fixture photos, no camera
#   sh tests/e2e_live.sh camera     camera mode: the real window and webcam take two
#                                   photos on a countdown (first run asks for access)
#
# Splits a scratch pane, starts Claude Code in it, and runs the real launcher against
# the real herdr socket with the test build of HerdrCam.app (the one with test hooks).
# Passes when Claude Code shows "[Image #1] [Image #2]" in its prompt. It also fires
# the doctor action through herdr's own plugin runner.
#
# Nothing here touches your config.env or captures: state goes to a temp dir, and the
# photos are pasted into the scratch pane by id, not into whatever has focus.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
herdr="${HERDR_BIN_PATH:-herdr}"
mode="${1:-fixture}"
fixture="$root/tests/fixtures/test.png"
tmp="$(mktemp -d)"
pane=""

cleanup() {
  [ -n "$pane" ] && "$herdr" pane close "$pane" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

sh "$root/scripts/build.sh" build/test --testing >/dev/null

pane="$("$herdr" pane split --current --direction down --ratio 0.4 --no-focus --cwd "$root" |
  plutil -extract result.pane.pane_id raw -o - -)"

wait_for() {
  i=0
  while [ $i -lt "$2" ]; do
    "$herdr" pane read "$pane" --source visible --lines 60 2>/dev/null | grep -qF "$1" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

"$herdr" pane run "$pane" "claude" >/dev/null
wait_for "❯" 40 || {
  echo "FAIL: claude prompt never appeared"
  exit 1
}
sleep 2

export HERDR_PANE_ID="$pane"
export HERDR_PLUGIN_STATE_DIR="$tmp/state"
export HERDR_CAM_APP="$root/build/test/HerdrCam.app"
export HERDR_CAM_NO_DETACH=1
export HERDR_CAM_NO_REFOCUS=1
wait_secs=20
if [ "$mode" = camera ]; then
  export HERDR_CAM_AUTO_CAPTURE=5 HERDR_CAM_AUTO_SHOTS=2
  wait_secs=90 # room for the one-time camera permission prompt
else
  export HERDR_CAM_FAKE_IMAGES="$fixture:$fixture"
fi
"$root/bin/herdr-cam" capture

if wait_for "[Image #1] [Image #2]" "$wait_secs"; then
  echo "e2e ($mode): PASS (two photos pasted into Claude Code as [Image #1] [Image #2])"
  tail -1 "$tmp/state/herdr-cam.log" 2>/dev/null || true
else
  echo "e2e ($mode): FAIL; pane shows:"
  "$herdr" pane read "$pane" --source visible --lines 12
  exit 1
fi

# The plugin as herdr runs it: manifest, action runner, environment.
"$herdr" plugin action invoke rchougule.cam.doctor >/dev/null
sleep 1
if "$herdr" plugin log list --plugin rchougule.cam | grep -q '"action_id":"doctor".*"status":"succeeded"'; then
  echo "e2e: PASS (doctor action ran through herdr's plugin runner)"
else
  echo "e2e: FAIL; doctor action did not succeed through herdr"
  exit 1
fi
