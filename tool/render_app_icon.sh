#!/bin/sh
# Renders the launcher icon from the SVGs in assets/icon/ into every PNG Android
# asks for.
#
# Usage:
#   sh tool/render_app_icon.sh
#
# Then rebuild the APK — launchers cache the icon, so an install alone can keep
# showing the old one.
#
# WHY SVG IS THE SOURCE. Android does not read SVG, and the alternative —
# exporting by hand from a design tool — makes the icon a binary nobody can
# regenerate, which is how a mark drifts away from the palette it was drawn
# from. One vector, one command, every density, and the geometry stays
# reviewable in a diff.
#
# WHY THE MARK'S SIZE IS COMPUTED AND NOT TYPED IN. It used to be two hand-picked
# percentages, and one of them was wrong in a way no file in this repo could
# show: placed at 60% of the adaptive canvas, the mark's corners reached 170 px
# from the centre, while the 66 dp safe circle a launcher is allowed to cut into
# has a radius of 132 px. On a device that masks the icon to a circle, the
# corners were shaved — the icon read as touching the edge. So the legacy
# percentage is now a composition choice with margin to spare, and the adaptive
# one is DERIVED: the artwork's reach is measured from its rendered pixels each
# run, and the mark is scaled to fit the safe circle. A new mark cannot
# reintroduce the bug by being a different shape. The check at the end fails the
# run if the ink still leaves the circle.
#
# WHY THERE ARE SO MANY OUTPUTS. Not redundancy: three contracts Android has had
# over time, and a given device uses exactly one.
#
#   1. mipmap-*/ic_launcher.png — five densities, 48 to 192. The finished icon,
#      tile included. Used by launchers older than API 26, and by the Android 12
#      splash screen, which is why it has to stand on its own.
#   2. drawable/ic_launcher_foreground.png — one 432x432 file (108dp @ xxxhdpi)
#      holding the MARK ONLY, on transparency. An adaptive launcher supplies the
#      shape and the background itself and composites this on top, so a
#      background baked in here would be masked into a rounded square floating
#      inside the launcher's circle. One file rather than five because
#      `drawable/` is density-agnostic and the system scales it.
#   3. the same file again, as the `monochrome` layer in
#      mipmap-anydpi-v26/ic_launcher.xml. Android 13+ repaints it in a single
#      system colour, which only works because the mark is one flat colour on
#      transparency and its prompt is a real hole rather than a dark shape.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MARK="$ROOT/assets/icon/mark.svg"
TILE="$ROOT/assets/icon/tile.svg"
RES="$ROOT/android/app/src/main/res"

# Legacy tiles are never cropped, so this is purely how big the art should look
# on the tile: 62% leaves the tile's rounded corner empty and still reads at
# 48 px. It is not the adaptive number and the two are not meant to agree — art
# sized for a tile that is never cropped is too big for one that is.
LEGACY_PCT=62

# The adaptive canvas: 108dp at xxxhdpi. A launcher may crop to the central
# 66dp circle, so that circle is the budget the artwork has to fit inside.
CANVAS=432
SAFE_R=132        # 66dp / 2, in px at this canvas size
SAFE_FIT=92       # % of the safe radius the artwork is allowed to reach

for f in "$MARK" "$TILE"; do
  if [ ! -f "$f" ]; then
    echo "missing $f" >&2
    exit 1
  fi
done

for tool in rsvg-convert magick python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      rsvg-convert) hint="brew install librsvg" ;;
      magick)       hint="brew install imagemagick" ;;
      *)            hint="brew install python3" ;;
    esac
    echo "$tool not found — install it with: $hint" >&2
    exit 1
  fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# How far the ink reaches from the artwork's centre, in px. The pixels are what
# matter, not the bounding box: a nearly square mark still reaches further at
# its corners than at its edges, and the corners are precisely what a round
# launcher mask takes off.
max_radius() {
  w=$(magick identify -format '%w' "$1")
  h=$(magick identify -format '%h' "$1")
  magick "$1" -alpha extract -depth 8 gray:- | python3 -c '
import sys
w, h = int(sys.argv[1]), int(sys.argv[2])
data = sys.stdin.buffer.read()
cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
best = 0.0
for y in range(h):
    row = y * w
    for x in range(w):
        if data[row + x] > 127:
            d = (x - cx) ** 2 + (y - cy) ** 2
            if d > best:
                best = d
print(best ** 0.5)' "$w" "$h"
}

# --- The mark, measured at a size where its edges are not quantised ---------
rsvg-convert -w 600 "$MARK" -o "$TMP/mark.png"
magick "$TMP/mark.png" -trim +repage "$TMP/mark-trim.png"
mark_w=$(magick identify -format '%w' "$TMP/mark-trim.png")
mark_h=$(magick identify -format '%h' "$TMP/mark-trim.png")
mark_r=$(max_radius "$TMP/mark-trim.png")
fg_px=$(python3 -c "print(int($SAFE_FIT / 100.0 * $SAFE_R * $mark_w / $mark_r))")

# --- 1. Finished tiles, one per density -----------------------------------
# The mark fills LEGACY_PCT of the tile. Enough to read at 48px, far enough from
# the edge that the tile's own corner radius never crowds it.
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  bucket=${pair%%:*}
  px=${pair##*:}
  mark=$((px * LEGACY_PCT / 100))

  mkdir -p "$RES/mipmap-$bucket"
  rsvg-convert -w "$px" -h "$px" "$TILE" -o "$TMP/tile.png"
  rsvg-convert -w "$mark" "$MARK" -o "$TMP/m.png"
  magick "$TMP/tile.png" "$TMP/m.png" -gravity center -composite \
    "$RES/mipmap-$bucket/ic_launcher.png"
  echo "  mipmap-$bucket/ic_launcher.png  ${px}x${px}  (mark ${mark}px)"
done

# --- 1b. The README logo ---------------------------------------------------
#
# The same composite at a size nothing on Android asks for. The README shows it
# at about 96 points, so this is a 4x asset — crisp on a HiDPI display, and one
# file is not worth a density ladder.
#
# Generated rather than exported by hand for the reason this whole script
# exists: a binary nobody can regenerate is how a mark drifts away from the
# palette it was drawn from. Change mark.svg, run this, and the README follows.
LOGO_PX=384
LOGO_OUT="$ROOT/docs/logo.png"
mkdir -p "$(dirname "$LOGO_OUT")"
rsvg-convert -w "$LOGO_PX" -h "$LOGO_PX" "$TILE" -o "$TMP/tile.png"
rsvg-convert -w "$((LOGO_PX * LEGACY_PCT / 100))" "$MARK" -o "$TMP/m.png"
magick "$TMP/tile.png" "$TMP/m.png" -gravity center -composite "$LOGO_OUT"
echo "  docs/logo.png  ${LOGO_PX}x${LOGO_PX}  (mark $((LOGO_PX * LEGACY_PCT / 100))px)"

# --- 2 & 3. The adaptive foreground ---------------------------------------
mkdir -p "$RES/drawable"
rsvg-convert -w "$fg_px" "$MARK" -o "$TMP/fg.png"
magick "$TMP/fg.png" -background none -gravity center \
  -extent "${CANVAS}x${CANVAS}" "$RES/drawable/ic_launcher_foreground.png"
echo "  drawable/ic_launcher_foreground.png  ${CANVAS}x${CANVAS}  (mark ${fg_px}px)"

# --- Verify, do not trust --------------------------------------------------
# Every opaque pixel has to sit inside the safe circle. Counting the ink inside
# the circle and comparing it against the ink in total catches a mark that
# reaches past it, which is the failure this script exists to prevent.
magick -size "${CANVAS}x${CANVAS}" xc:black -fill white \
  -draw "circle $((CANVAS / 2)),$((CANVAS / 2)) $((CANVAS / 2)),$((CANVAS / 2 - SAFE_R))" \
  "$TMP/safe.png"
total=$(magick "$RES/drawable/ic_launcher_foreground.png" -alpha extract \
  -format '%[fx:mean]' info:)
inside=$(magick "$RES/drawable/ic_launcher_foreground.png" -alpha extract "$TMP/safe.png" \
  -compose multiply -composite -format '%[fx:mean]' info:)
python3 -c "
total, inside = $total, $inside
outside = total - inside
if outside > 1e-6:
    raise SystemExit(
        'the mark reaches outside the %dpx safe circle: %.4f%% of its ink is outside.\n'
        'Shrink SAFE_FIT, or the artwork, before shipping this.'
        % ($SAFE_R, 100.0 * outside / total))
print('  safe-zone check: every pixel of ink is inside the %dpx (66dp) circle' % $SAFE_R)
print('  artwork reach:   %.1f%% of that radius, aspect %.2f:1'
      % (100.0 * $mark_r / $mark_w * $fg_px / $SAFE_R, $mark_w / $mark_h))"

echo "done — rebuild the APK; launchers cache icons across a plain reinstall"
