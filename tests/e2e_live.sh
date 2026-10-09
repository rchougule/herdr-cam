#!/bin/sh
# Live end-to-end test. Needs a running herdr, the `claude` CLI, and a built app.
# Not run in CI.
#
#   sh tests/e2e_live.sh            fixture mode: camera swapped for tests/fixtures/test.png
#   sh tests/e2e_live.sh camera     camera mode: real window, real webcam, auto-capture
#                                   after a countdown (first run asks for camera access)
#
# It splits a scratch pane, starts Claude Code in it, focuses it, and fires the real
# plugin action through herdr (`herdr plugin action invoke rchougule.cam.capture`).
# Everything else is real: herdr's action runner, the detached worker, `open -W` on
# HerdrCam.app, the image pipeline, and the bracketed paste over the herdr socket.
# Passes when Claude Code shows "[Image #1]" in its prompt.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
herdr="${HERDR_BIN_PATH:-herdr}"
fixture="$root/tests/fixtures/test.png"
mode="${1:-fixture}"

[ -x "$root/build/HerdrCam.app/Contents/MacOS/HerdrCam" ] || sh "$root/scripts/build.sh"
"$herdr" plugin list 2>/dev/null | grep -q rchougule.cam || "$herdr" plugin link "$root" >/dev/null

conf_dir="$("$herdr" plugin config-dir rchougule.cam)"
conf="$conf_dir/config.env"
backup=""
if [ -f "$conf" ]; then
  backup="$(mktemp)"
  cp "$conf" "$backup"
fi

origin="$("$herdr" pane current | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')"
pane="$("$herdr" pane split --current --direction down --ratio 0.4 --no-focus --cwd "$root" |
  sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')"

cleanup() {
  if [ -n "$backup" ]; then mv "$backup" "$conf"; else rm -f "$conf"; fi
  "$herdr" pane close "$pane" >/dev/null 2>&1 || true
  [ -n "$origin" ] && "$herdr" agent focus "$origin" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

{
  [ -n "$backup" ] && cat "$backup"
  if [ "$mode" = camera ]; then
    echo "HERDR_CAM_AUTO_CAPTURE=6"
  else
    echo "HERDR_CAM_FAKE_IMAGE=$fixture"
  fi
} >"$conf"
wait_secs=20
[ "$mode" = camera ] && wait_secs=90 # room for the one-time camera permission prompt

# Focus the scratch pane so the action targets it, exactly as the keybinding would.
# Refuse to fire otherwise, so the photo never lands in whichever pane ran this test.
"$herdr" agent focus "$pane" >/dev/null
"$herdr" pane get "$pane" | grep -q '"focused":true' || {
  echo "FAIL: could not focus scratch pane $pane"
  exit 1
}
"$herdr" plugin action invoke rchougule.cam.capture >/dev/null

if wait_for "[Image #1]" "$wait_secs"; then
  echo "e2e ($mode): PASS (photo pasted into Claude Code as [Image #1])"
  tail -1 "$HOME/.local/state/herdr/plugins/rchougule.cam/herdr-cam.log"
else
  echo "e2e: FAIL; pane shows:"
  "$herdr" pane read "$pane" --source visible --lines 12
  exit 1
fi
