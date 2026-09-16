#!/usr/bin/env bash
#
# The on-device acceptance checks, replayed.
#
# WHY THIS EXISTS. The safety-margin and pull-to-refresh work was verified by
# hand: `adb shell input tap` at coordinates read off a screenshot, then a PNG
# opened and eyeballed. That works once and costs twice — two of the taps landed
# in the gap between controls and half an hour went into suspecting the app. To
# check it again later, all of it had to be redone by hand.
#
# SO THE CHECKS ASSERT. Each one prints PASS or FAIL and exits non-zero on
# failure; there is nothing to look at afterwards. Where a screenshot is the only
# honest evidence — which refresh animation played — the check saves it AND
# compares the frames against each other, so "a different one every time" is
# asserted rather than seen.
#
# AND THEY ADDRESS THE UI BY LABEL. `uiautomator dump` returns Flutter's own
# semantics tree, labels and bounds included, so a tap is "the centre of 安全边界"
# — which does not care about screen size, density, or where the card moved to.
#
# Usage:
#   tool/device_check.sh margins    # 安全边界: three values, geometry must follow
#   tool/device_check.sh refresh    # three pulls, three different animations
#   tool/device_check.sh all
#
# Requirements: adb on PATH with one device attached, and `magick` — the same
# dependency tool/render_app_icon.sh already has.

set -euo pipefail

# The margin the app keeps clear of the system's edge gestures. MUST match
# `kSafetyInset` in lib/ui/design/safety_inset.dart: the check asserts the
# DISTANCE between two states, so a drift between the two shows up as a wrong
# delta rather than as a test that passes over nothing.
SAFETY_INSET_DP=16

APP_ID=dev.herdr.herdr_pocket
WORK="${TMPDIR:-/tmp}/herdr-device-check"
mkdir -p "$WORK"
UI_XML="$WORK/ui.xml"
COLUMN_TXT="$WORK/column.txt"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- device facts -----------------------------------------------------------

DPR=$(python3 -c "print($(adb shell wm density | tr -d '\r' | awk '{print $3}') / 160)")
SCREEN_SIZE=$(adb shell wm size | tr -d '\r' | awk '{print $3}')
SCREEN_W=${SCREEN_SIZE%x*}
SCREEN_H=${SCREEN_SIZE#*x}

shot() { adb exec-out screencap -p > "$1"; }

# --- driving the UI by label ------------------------------------------------

# Dumped to a FILE rather than piped into the parser below, because that parser
# reads its program from a heredoc and a heredoc REPLACES stdin — a pipe into
# `python3 - <<PY` delivers nothing at all, which reads exactly like "the app
# exposes no semantics".
ui_dump() {
  # EVERY failure tolerated, deliberately. `uiautomator dump` fails whenever the
  # window is not ready — which is exactly the state the launch loop below is
  # waiting through — and `cat` then fails on a file that was never written.
  # Under `set -e` those two aborts killed the script SILENTLY, halfway through
  # a wait, with no output at all.
  adb shell uiautomator dump /sdcard/herdr-ui.xml >/dev/null 2>&1 || true
  { adb shell cat /sdcard/herdr-ui.xml 2>/dev/null || true; } |
    tr -d '\r' > "$UI_XML"
}

# "<x> <y>" for the centre of a node: by ID when the argument is `#some-id`,
# by label otherwise — or nothing when there is no such node.
#
# WHY IDS COME FIRST. A label is user-facing text: it is translated, it changes
# with state, and two nodes can carry the same words. The moment 强制开启 is the
# current value, the safety ROW and the safety MENU ITEM both say it, and a
# label-addressed tap picks whichever the tree lists first — a coin flip that
# passes often enough to look fine. `Semantics(identifier:)` reaches Android as
# the node's resource-id, so `#safety-margin` means exactly one control.
ui_where() {
  ui_dump
  python3 - "$UI_XML" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
want = sys.argv[2]

nodes = [
    dict(re.findall(r'(\w[\w-]*)="([^"]*)"', attrs))
    for attrs in re.findall(r'<node ([^>]*?)/?>', xml)
]


def centre(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node['bounds']))
    return (x1 + x2) // 2, (y1 + y2) // 2


if want.startswith('#'):
    marked = [n for n in nodes if n.get('resource-id') == want[1:]]
    if len(marked) > 1:
        sys.exit('duplicate resource-id %s: %d nodes' % (want, len(marked)))
    if marked:
        print(*centre(marked[0]))
    raise SystemExit

# A label is a last resort: Flutter puts it in `content-desc` for a control and
# in `text` for plain text, and joins a multi-line row with &#10;.
for node in nodes:
    row = (node.get('text', '') + '\n' + node.get('content-desc', ''))
    if want in row.replace('&#10;', '\n'):
        print(*centre(node))
        break
PY
}

ui_tap() {
  local where
  where=$(ui_where "$1")
  [ -n "$where" ] || fail "no node labelled '$1' — is the right page open?"
  # shellcheck disable=SC2086
  adb shell input tap $where
  sleep 0.9
}

# The whole row as a reader sees it, for asserting that a change took effect.
ui_text() {
  ui_dump
  python3 - "$UI_XML" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
want = sys.argv[2]
for text, desc in re.findall(r'text="([^"]*)"[^>]*content-desc="([^"]*)"', xml):
    row = (text + '|' + desc).replace('&#10;', '\n')
    if want in row:
        left, _, right = row.partition('|')
        print((right or left).strip())
        break
PY
}

# --- reading pixels ---------------------------------------------------------

# How far the dock's bottom edge sits above the window bottom, in dp.
#
# Scans UP a column at x=350 — inside the dock's pill, clear of the gesture
# handle, which is centred and would otherwise be the first thing found.
dock_gap_dp() {
  magick "$1" -crop "1x${SCREEN_H}+350+0" +repage txt:- | tail -n +2 > "$COLUMN_TXT"
  python3 - "$COLUMN_TXT" "$DPR" <<'PY'
import re, sys
rows = []
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    # `0,<y>:` — the column is one pixel wide, so x is always 0 and the y is
    # the SECOND number. Reading the first one as y made every row row zero,
    # and that surfaced as a StopIteration from the ground lookup rather than
    # as anything mentioning coordinates.
    m = re.match(r'\d+,(\d+): \((\d+),(\d+),(\d+)', line)
    if m:
        rows.append((int(m.group(1)),
                     (int(m.group(2)), int(m.group(3)), int(m.group(4)))))
rows.sort()
if not rows:
    print('')
    raise SystemExit
ground = next(c for y, c in rows if y == 1200)  # a row well above the dock
for y, c in reversed(rows):
    if all(c[i] > ground[i] + 6 for i in range(3)):
        print(round((rows[-1][0] - y) / float(sys.argv[2]), 1))
        break
else:
    print('')
PY
}

# --- the app ----------------------------------------------------------------

# Starts the app and WAITS FOR IT TO BE UP — by looking, not by sleeping.
#
# A fixed sleep is how this script first lied to me: the emulator takes ~20s to
# draw the first frame after a cold start, a dump taken inside that window
# returned the PREVIOUS process's tree, and the two fixes it was checking looked
# like they had not worked. A check that cannot tell "not ready" from "wrong"
# will eventually report the wrong thing.
launch() {
  adb shell am force-stop "$APP_ID"
  adb shell am start -n "$APP_ID/.MainActivity" >/dev/null
  local i
  for i in $(seq 1 "${1:-40}"); do
    sleep 1
    ui_dump
    # `if`, not `&&`: an AND-list that ends the last iteration non-zero is an
    # errexit tripwire, and the symptom is a script that stops with no message.
    if grep -q 'resource-id="dock-board"' "$UI_XML"; then
      sleep 1
      return 0
    fi
  done
  fail 'the app never came up: no dock in the semantics tree'
}

open_settings() {
  ui_tap '#dock-settings'
  sleep 1
}

# Sets 安全边界 and then READS IT BACK: a measurement taken after a tap that did
# not land is worse than no measurement, because it looks like a result.
#
# $1 is the option's ID — how it is TARGETED. $2 is the word the row should then
# show — how it is CONFIRMED, and the only locale-dependent part of this file,
# because the row displays text and there is no id in the text.
set_safety_margin() {
  ui_tap '#safety-margin'
  ui_tap "#$1"
  local row
  row=$(ui_text '安全边界')
  case "$row" in
    *"$2"*) : ;;
    *) fail "安全边界 did not take $1 (the row reads: ${row:-<nothing>})" ;;
  esac
}

# --- checks -----------------------------------------------------------------

check_margins() {
  say "== 安全边界: the chrome must keep clear of the system's edge gestures =="
  say "   device ${SCREEN_W}x${SCREEN_H} px, density ${DPR} dp"

  launch
  open_settings

  set_safety_margin 'safety-always-on' '强制开启'
  ui_tap '#dock-board'
  sleep 1.2
  shot "$WORK/margin-on.png"
  local on
  on=$(dock_gap_dp "$WORK/margin-on.png")

  open_settings
  set_safety_margin 'safety-always-off' '强制关闭'
  ui_tap '#dock-board'
  sleep 1.2
  shot "$WORK/margin-off.png"
  local off
  off=$(dock_gap_dp "$WORK/margin-off.png")

  [ -n "$on" ] && [ -n "$off" ] || fail "the dock was not found in the screenshots"

  local delta
  delta=$(python3 -c "print(round($on - $off, 1))")
  say "   dock bottom: ${on}dp above the window edge with the margin, ${off}dp without"
  say "   delta ${delta}dp, expected ${SAFETY_INSET_DP}dp"

  # A verification script that leaves the device on a test setting breaks the
  # next thing it verifies.
  open_settings
  set_safety_margin 'safety-default' '默认'

  python3 -c "raise SystemExit(0 if abs($delta - $SAFETY_INSET_DP) < 1.0 else 1)" \
    || fail "the margin moved the chrome by ${delta}dp, not ${SAFETY_INSET_DP}dp"
  say "PASS: the safety margin moves the chrome by exactly ${SAFETY_INSET_DP}dp"
}

check_refresh() {
  say "== pull to refresh: three pulls, three different animations =="
  launch
  # The board, and no connection needed: the gesture and its animation are local.
  ui_tap '#dock-board'

  local i y
  for i in 1 2 3; do
    # `motionevent` rather than `input swipe`: the panel is most interesting
    # while the finger is still down, and a swipe runs to completion first.
    adb shell input motionevent DOWN 540 900
    for y in 1100 1300 1500 1700; do
      adb shell input motionevent MOVE 540 "$y"
      sleep 0.1
    done
    sleep 0.3
    shot "$WORK/refresh-$i.png"
    adb shell input motionevent UP 540 1700
    sleep 1.6
  done

  # "a different one every time" is the promise, so it is the assertion. WHICH
  # style each frame shows stays a matter for the eye — this is the rotation,
  # not the artwork.
  local a b c
  a=$(magick "$WORK/refresh-1.png" -format '%#' info:)
  b=$(magick "$WORK/refresh-2.png" -format '%#' info:)
  c=$(magick "$WORK/refresh-3.png" -format '%#' info:)
  {
    [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$a" != "$c" ]
  } || fail "two of the three pulls rendered the same frame"

  say "   three distinct frames saved to $WORK"
  say "PASS: the animation changes between pulls"
}

case "${1:-all}" in
  margins) check_margins ;;
  refresh) check_refresh ;;
  all)
    check_margins
    say
    check_refresh
    ;;
  *) fail "unknown check '$1' (margins | refresh | all)" ;;
esac
