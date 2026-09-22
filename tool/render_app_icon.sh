#!/bin/sh
# Renders the launcher icon from the SVGs in assets/icon/ into every PNG Android
# and iOS ask for.
#
# Usage:
#   sh tool/render_app_icon.sh
#
# Then rebuild the APK — launchers cache the icon, so an install alone can keep
# showing the old one. iOS does not cache across a reinstall, but Xcode does
# cache the compiled asset catalog, so build as usual and it follows.
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
#
# --- iOS, same mark, two different rules ------------------------------------
#
#   4. ios/Runner/Assets.xcassets/AppIcon.appiconset — fifteen PNGs, and the
#      constraints are NOT Android's:
#
#      * NO ALPHA CHANNEL. An icon with alpha is rejected on submission, and the
#        tile is opaque anyway — so the alpha is stripped rather than carried.
#      * NO ROUNDED CORNERS AND NO MARGIN. `tile.svg` is a 22%-radius rounded
#        square because older Android launchers draw that file AS the icon.
#        iOS does the opposite: the system masks the icon to its own squircle,
#        so a rounded tile inside that mask shows the background through four
#        slivers of corner. iOS gets a FULL-BLEED SQUARE and lets the system
#        round it. Same two colours, different substrate.
#      * The mark keeps the legacy 62%: iOS does not crop the artwork, but the
#        system's mask does cut the corners, so the one thing worth checking is
#        that no ink reaches them. That check runs below.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MARK="$ROOT/assets/icon/mark.svg"
TILE="$ROOT/assets/icon/tile.svg"
RES="$ROOT/android/app/src/main/res"
ASSETS="$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"

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

# --- 4. iOS: the same tile and mark, square and opaque ----------------------
#
# Sizes are the ones `Contents.json` already declares, and the file names are
# the ones it already references — this rewrites the PIXELS and never the
# catalog. Adding a device family in Xcode means adding its size here too, which
# is the point: the list of sizes belongs to the platform, and duplicating it in
# a shell array is how it silently falls behind.
IOS_FILES="20x20@1x:20 20x20@2x:40 20x20@3x:60
29x29@1x:29 29x29@2x:58 29x29@3x:87
40x40@1x:40 40x40@2x:80 40x40@3x:120
60x60@2x:120 60x60@3x:180
76x76@1x:76 76x76@2x:152 83.5x83.5@2x:167
1024x1024@1x:1024"

mkdir -p "$ASSETS"

# Fail BEFORE writing fifteen files, not after: the check is about geometry, so
# it is answered by the artwork alone.
#
# The system's mask is a squircle, which CONTAINS the inscribed circle: a point
# inside that circle is inside the mask for certain, and a point on a corner of
# the square is not. So measuring the artwork's reach against the half-width is a
# conservative test for "the mask cannot shave it" — and unlike a hand-checked
# screenshot it fails the BUILD instead of shipping.
rsvg-convert -w 2048 "$MARK" -o "$TMP/ios_measure.png"
magick "$TMP/ios_measure.png" -trim +repage "$TMP/ios_measure_trim.png"
mw=$(magick identify -format '%w' "$TMP/ios_measure_trim.png")
mr=$(max_radius "$TMP/ios_measure_trim.png")
python3 -c "
mw, mr = float($mw), float($mr)
# The mark is composited at LEGACY_PCT of the icon and centred, so the ink's
# reach in icon pixels is mr scaled by (mark_width / artwork_width), and the
# question is what fraction that is of the icon's half-width (px / 2). Both px
# and mark_width cancel, leaving this:
frac = (mr / mw) * ($LEGACY_PCT / 100.0) * 2.0
print('  iOS safe-circle check: artwork reaches %.1f%% of the icon half-width' % (100.0 * frac))
if frac > 1.0:
    raise SystemExit(
        'the mark reaches past the inscribed circle, which the iOS mask is '
        'guaranteed to contain, so the corners would be shaved: %.1f%%.\\n'
        'Shrink LEGACY_PCT or the artwork.' % (100.0 * frac))
"

for pair in $IOS_FILES; do
  name=${pair%%:*}
  px=${pair##*:}
  mark=$((px * LEGACY_PCT / 100))
  [ "$mark" -lt 1 ] && mark=1

  # A white square drawn directly: `tile.svg`'s rounded rect is Android's
  # framing, and re-rendering it here would bake those corners into an icon the
  # system is about to round again.
  rsvg-convert -w "$mark" "$MARK" -o "$TMP/ios_m.png"
  magick -size "${px}x${px}" xc:white "$TMP/ios_m.png" -gravity center \
    -composite -alpha remove -alpha off "PNG24:$ASSETS/Icon-App-$name.png"
  echo "  AppIcon.appiconset/Icon-App-$name.png  ${px}x${px}  (mark ${mark}px)"
done

echo "done — rebuild the APK (launchers cache icons across a plain reinstall) and the"
echo "       iOS app (Xcode caches the compiled asset catalog, but a rebuild picks it up)."
