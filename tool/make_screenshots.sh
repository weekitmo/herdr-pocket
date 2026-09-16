#!/bin/sh
#
# Turns two raw on-device screenshots into the two images the README shows.
#
# ## Where the raw shots come from
#
# `patrol test --no-label --screenshots-output-dir <dir>`, from a throwaway test
# that pairs the emulator with a real daemon and then calls
# `$.takeNativeScreenshot('board')` / `('terminal')`. `--no-label` matters: by
# default Patrol draws the running test's name over the app in red.
#
# ## What this script does, and why each step exists
#
#   1. REDACT      — a real screenshot of this app contains a real workspace
#                    name from the machine it is talking to. Repainted in the
#                    app's own font at the app's own size and colour, so the
#                    image reads as the product rather than as a censored
#                    document. (Blur was the first attempt; it looks like a bug.)
#   2. CROP        — Android's three-button navigation bar is not part of the
#                    app and would sit inside a phone frame looking wrong.
#   3. STATUS BAR  — the Android clock and battery icons are painted out with
#                    the page's own ground colour, so the frame's Dynamic Island
#                    is the only status chrome. Nothing of the app is lost: the
#                    app draws edge to edge and owns none of that strip.
#   4. FRAME       — drawn here, not downloaded. A stock "iPhone mockup" PNG is
#                    somebody's artwork with a licence attached, and this needs
#                    a rounded rectangle, a pill and five small ones.
#
# Usage:
#   sh tool/make_screenshots.sh board.png terminal.png
#
# Requirements: `magick` (ImageMagick 7), as tool/render_app_icon.sh already has.
set -eu

cd "$(dirname "$0")/.."

OUT_DIR="${HP_SHOT_OUT:-docs/screenshots}"
FONT=assets/fonts/IosevkaNerdFontMono-Regular.ttf

[ $# -eq 2 ] || { echo "usage: $0 <board.png> <terminal.png>" >&2; exit 2; }
BOARD="$1"
TERMINAL="$2"

command -v magick >/dev/null 2>&1 || {
  echo "magick is not on PATH — brew install imagemagick" >&2
  exit 1
}
[ -f "$FONT" ] || { echo "missing $FONT" >&2; exit 1; }

mkdir -p "$OUT_DIR" /tmp/hp-shots
work=/tmp/hp-shots

# ----------------------------------------------------------------- redact ---
#
# Coordinates are in the raw 1080x1920 screenshots and were measured off crops
# of them. If the app's card layout changes enough to move these, the images
# will show a painted-over strip in the wrong place — so re-measure rather than
# nudging: a redaction that misses is worse than none.
#
# The rectangles also stop well inside the CARD. A patch that ran to the edge
# of the image squared off the card's rounded corner with a visible tab of the
# card's own colour — obvious at a glance, and the reason the widths here look
# arbitrary.

magick "$BOARD" \
  -fill '#343A46' -draw 'rectangle 400,346 820,400' \
  -fill '#343A46' -draw 'rectangle 226,460 620,502' \
  -font "$FONT" -pointsize 37 -fill '#DFE2E8' -annotate +402+388 'my-project' \
  -font "$FONT" -pointsize 32 -fill '#9CA0A7' -annotate +228+491 'my-project' \
  "$work/board-redacted.png"

# THE WHOLE STATUS LINE, redrawn rather than patched. Patching just the
# sensitive word left a sliver of the original glyph beside the new text — a
# one-pixel stem that reads as a rendering defect at any zoom — because finding
# the exact pixel where one letter ends is guesswork. A monospace line can be
# redrawn outright, and then there is no seam to find.
magick "$TERMINAL" \
  -fill '#2E3440' -draw 'rectangle 0,1606 1070,1657' \
  -font "$FONT" -pointsize 31 -fill '#9A9A9A' \
  -annotate +8+1644 '[gw-ai-openai/deepseek-flash @max]  Apps/my-project  main' \
  -fill '#2E3440' -draw 'rectangle 175,95 470,137' \
  -font "$FONT" -pointsize 33 -fill '#C8CCD4' -annotate +179+124 'dsh · my-project' \
  "$work/terminal-redacted.png"

# ------------------------------------------------------- strip the platform --
#
# 1830 of 1920 keeps everything above Android's navigation bar. The top strip is
# painted with the ground colour sampled from the page itself, a few pixels
# below the icons, so it matches whatever theme the screenshot was taken in.

strip_platform() {
  source="$1"
  out="$2"
  ground="$(magick "$source" -crop 1x1+40+40 +repage -format '%[hex:p{0,0}]' info:)"
  magick "$source" \
    -crop 1080x1830+0+0 +repage \
    -fill "#$ground" -draw 'rectangle 0,0 1080,60' \
    -resize 900x \
    "$out"
}

strip_platform "$work/board-redacted.png" "$work/board-screen.png"
strip_platform "$work/terminal-redacted.png" "$work/terminal-screen.png"

# ----------------------------------------------------------------- frame ----
#
# Proportions rather than an exact iPhone spec: the screen is what it is, and
# the frame is drawn around it. Distorting the screenshot to hit a device's real
# aspect ratio would make the app look wrong to fix the phone.

frame() {
  screen="$1"
  out="$2"

  W=$(magick identify -format '%w' "$screen")
  H=$(magick identify -format '%h' "$screen")
  bezel=26
  margin=14
  body_w=$((W + 2 * bezel))
  body_h=$((H + 2 * bezel))
  canvas_w=$((body_w + 2 * margin))
  canvas_h=$((body_h + 2 * margin))

  # The screen, with its corners rounded so it sits inside the bezel rather than
  # under it.
  magick -size "${W}x${H}" xc:none -fill white \
    -draw "roundrectangle 0,0,$((W - 1)),$((H - 1)),52,52" "$work/mask.png"
  magick "$screen" "$work/mask.png" -alpha off -compose CopyOpacity -composite \
    "$work/screen-round.png"

  # The body: one rounded rectangle, a hairline of lighter metal inside its
  # edge, and the side buttons drawn as small pills hanging off it.
  magick -size "${canvas_w}x${canvas_h}" xc:none \
    -fill none -stroke '#4a4a4f' -strokewidth 1 \
    -draw "roundrectangle $margin,$margin,$((margin + body_w - 1)),$((margin + body_h - 1)),78,78" \
    -stroke none -fill '#232326' \
    -draw "roundrectangle $margin,$margin,$((margin + body_w - 1)),$((margin + body_h - 1)),78,78" \
    -stroke '#5a5a60' -strokewidth 2 -fill none \
    -draw "roundrectangle $((margin + 2)),$((margin + 2)),$((margin + body_w - 3)),$((margin + body_h - 3)),76,76" \
    -stroke none -fill '#1c1c1f' \
    -draw "roundrectangle $((margin - 3)),$((margin + 150)),$((margin + 2)),$((margin + 210)),4,4" \
    -draw "roundrectangle $((margin - 3)),$((margin + 250)),$((margin + 2)),$((margin + 380)),4,4" \
    -draw "roundrectangle $((margin - 3)),$((margin + 420)),$((margin + 2)),$((margin + 550)),4,4" \
    -draw "roundrectangle $((margin + body_w - 3)),$((margin + 320)),$((margin + body_w + 2)),$((margin + 500)),4,4" \
    "$work/body.png"

  # Screen on body, then the island on top of both.
  magick "$work/body.png" "$work/screen-round.png" -geometry "+$((margin + bezel))+$((margin + bezel))" \
    -composite \
    -fill '#0b0b0d' \
    -draw "roundrectangle $((margin + (body_w - 226) / 2)),$((margin + 46)),$((margin + (body_w - 226) / 2 + 226)),$((margin + 46 + 62)),31,31" \
    "$out"
}

frame "$work/board-screen.png" "$OUT_DIR/board.png"
frame "$work/terminal-screen.png" "$OUT_DIR/terminal.png"

magick identify "$OUT_DIR/board.png" "$OUT_DIR/terminal.png"
