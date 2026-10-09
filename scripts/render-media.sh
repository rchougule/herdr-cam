#!/bin/sh
# Renders the README media from the HTML sources in assets/src/ with headless Chrome:
#   assets/banner.png          README banner (1600x560)
#   assets/social-preview.png  GitHub social preview (1280x640)
#   assets/demo.gif            12s demo loop (960x600)
# Needs Google Chrome and gifski (`brew install gifski`); ffmpeg is the GIF fallback.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
src="file://$root/assets/src"
fps=15
duration=12

shot() { # url width height out
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size="$2,$3" --screenshot="$4" "$1" >/dev/null 2>&1
}

shot "$src/banner.html#banner" 800 280 assets/banner.png
shot "$src/banner.html#social" 640 320 assets/social-preview.png
echo "rendered assets/banner.png, assets/social-preview.png"

frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT
n=$((fps * duration))
frame_list() { # every frame index and its time, or only those not rendered yet
  i=0
  while [ $i -lt $n ]; do
    f="$(printf '%04d' "$i")"
    [ -s "$frames/$f.png" ] || printf '%s %s\n' "$f" "$(echo "scale=4; $i / $fps" | bc)"
    i=$((i + 1))
  done
}
# One Chrome per frame, 6 at a time. A launch occasionally fails under load, so rerun
# whatever is missing instead of giving up.
for _ in 1 2 3; do
  frame_list | xargs -P 6 -n 2 sh -c "
    '$chrome' --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --window-size=960,600 --screenshot='$frames'/\$0.png '$src/demo.html#t='\$1 >/dev/null 2>&1" || true
  [ -z "$(frame_list)" ] && break
done
missing="$(frame_list | wc -l | tr -d ' ')"
[ "$missing" -eq 0 ] || {
  echo "render-media: $missing demo frames failed to render" >&2
  exit 1
}

if command -v gifski >/dev/null 2>&1; then
  gifski --quiet --fps "$fps" --width 960 --quality 85 -o assets/demo.gif "$frames"/*.png
else
  ffmpeg -loglevel error -y -framerate "$fps" -i "$frames/%04d.png" \
    -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
    assets/demo.gif
fi
echo "rendered assets/demo.gif ($(du -h assets/demo.gif | cut -f1))"
