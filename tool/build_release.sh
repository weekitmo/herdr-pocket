#!/usr/bin/env bash
#
# Builds a release APK for a REAL DEVICE.
#
# WHAT THIS IS FOR. Debug builds are how the app gets developed; they are also
# slow, they keep their asserts, and they ship a JIT interpreter. Testing on a
# phone with a debug build means testing something the user will never run —
# the terminal repaints, the board scrolls and the glass blurs all behave
# differently once it is AOT-compiled. So: release mode, side-loaded.
#
# WHAT THIS IS NOT. A Play Store artifact. See the SIGNING section below, which
# is the one thing here that is deliberately not production-shaped.
#
# Usage:
#   tool/build_release.sh              # arm64 + armeabi-v7a, the usual case
#   tool/build_release.sh --universal  # one fat APK, any device, ~3x the size
#   tool/build_release.sh --skip-checks
set -euo pipefail

cd "$(dirname "$0")/.."

UNIVERSAL=0
SKIP_CHECKS=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- checks
#
# The build is the LAST step, not the first. A release APK that fails its own
# test suite is a file whose only purpose is to waste a side-load round trip.
if [ "$SKIP_CHECKS" -eq 0 ]; then
  step "flutter analyze"
  flutter analyze

  step "flutter test"
  # The live tests skip themselves when there is no daemon reachable, which is
  # the correct outcome here — this is a build, not a probe.
  flutter test

  step "icon provenance"
  # A vendored icon that no longer matches its recorded hash means somebody
  # edited third-party artwork in place. Fails loudly rather than shipping it.
  python3 tool/fetch_ui_icons.py --check
fi

# ---------------------------------------------------------------- build
step "flutter build apk --release"
OUT=build/app/outputs/flutter-apk
# Clear first, so the report below can only ever name a file this run produced.
# Without it the listing happily includes artifacts from previous builds — and,
# worse, from previous FLUTTER versions: an `armeabi-v7a` split from an older
# SDK sat there looking current until this was added.
rm -f "$OUT"/*.apk

if [ "$UNIVERSAL" -eq 1 ]; then
  flutter build apk --release
else
  flutter build apk --release --split-per-abi
fi

# ---------------------------------------------------------------- report
step "artifacts"
# shellcheck disable=SC2012
ls -lh "$OUT"/*.apk | awk '{printf "  %-38s %s\n", $9, $5}'

cat <<'SIZE'

  WHY IT IS THIS BIG. Roughly 30 of those megabytes are the two bundled fonts —
  Iosevka Nerd Font Mono (14 MB) and Noto Sans Mono CJK SC (16 MB). That is not
  slack to be trimmed: the terminal is a fixed grid, a Han glyph must occupy
  exactly two cells, and no font the platform ships can do that. See the comment
  above `fonts:` in pubspec.yaml before touching either.
SIZE

echo
echo "  install — one of these, matching the phone's CPU:"
echo "    Xiaomi MIX 2S / anything from the last decade:  arm64-v8a"
echo
for apk in "$OUT"/*.apk; do
  # Full path, so the line can be pasted from any directory.
  echo "    adb install -r $PWD/$apk"
done

cat <<'NOTE'

  SIGNING — read before shipping anywhere but this phone.

  This project signs release builds with the DEBUG key (Flutter's template
  default, `android/app/build.gradle.kts`). Two consequences, and the first one
  is a feature today:

    * `adb install -r` upgrades the copy already on the phone. Switching to a
      real keystore makes Android refuse the upgrade (INSTALL_FAILED_UPDATE_
      INCOMPATIBLE) and the app must be uninstalled first — which also deletes
      its saved hosts and its stored SSH credential.
    * The APK is therefore NOT distributable. For that, generate a keystore,
      add a `release` signing config, and keep the file out of the repository.

  Release mode itself is not affected by any of this: AOT compilation, R8, no
  asserts, no JIT — the thing being tested is the real one.
NOTE
