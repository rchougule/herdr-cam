#!/bin/sh
# Renders the README media from the HTML sources in assets/src/:
#   assets/banner.png          README banner (1600x560)
#   assets/social-preview.png  GitHub social preview (1280x640)
#   assets/demo.gif            17s demo loop (960x600)
# Needs Node, Google Chrome (driven by Playwright, no browser download), and ffmpeg;
# gifski is used instead of ffmpeg for the GIF when it is installed.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
fps=15

[ -d assets/node_modules/playwright-core ] || npm --prefix assets ci --silent
frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT
node assets/render.mjs "$frames"

if command -v gifski >/dev/null 2>&1; then
  gifski --quiet --fps "$fps" --width 960 --quality 85 -o assets/demo.gif "$frames"/*.png
else
  ffmpeg -loglevel error -y -framerate "$fps" -i "$frames/%04d.png" \
    -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
    assets/demo.gif
fi
echo "rendered assets/demo.gif ($(du -h assets/demo.gif | cut -f1))"
