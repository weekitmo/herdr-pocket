#!/bin/sh
# Runs `integration_test/ios_device_test.dart` on a booted iOS SIMULATOR.
#
# Usage:
#   sh tool/ios_sim_test.sh              # booted simulator, or the first available
#   sh tool/ios_sim_test.sh <udid>       # a specific one (`xcrun simctl list devices`)
#   sh tool/ios_sim_test.sh <udid> --no-sshd   # skip the live SSH group
#
# WHY A SCRIPT AND NOT JUST `flutter test integration_test/...`.
#
# The tests need three things that live on THIS MAC and not in the simulator, and
# the simulator cannot be asked for any of them:
#
#   1. the throwaway sshd's private key (`tool/test_sshd.sh` writes it to /tmp),
#   2. this machine's `$HOME`, because the herdr socket path is resolved on the
#      SERVER side of the SSH connection -- the simulator's own `$HOME` is its
#      sandbox, and forwarding to a socket there would reach nothing,
#   3. the login user, which is who the scratch sshd authenticates.
#
# They go in as `--dart-define`s, base64 for the key so that newlines survive
# the command line. Without them the live group skips and the file still
# verifies everything that does not need a network.
#
# ⚠️ THE SIMULATOR'S `127.0.0.1` IS THIS MAC. That is the whole reason the live
# group can exist at all without a second machine, and it is also why the port
# below is the scratch sshd's 2222 rather than 22: the machine's own sshd would
# mean adding a key to the developer's `authorized_keys`, which is a change to
# someone's security configuration made to run a test.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

UDID="${1:-}"
want_live=1
for arg in "$@"; do
  [ "$arg" = "--no-sshd" ] && want_live=0
done
[ "$UDID" = "--no-sshd" ] && UDID=""

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is not on PATH" >&2
  exit 1
}

# --- 1. A booted simulator -------------------------------------------------
if [ -z "$UDID" ]; then
  # THE BOOTED ONE FIRST, because that is the one the user is looking at -- a
  # test that runs somewhere else than the window on screen is a test whose
  # failures cannot be looked at.
  UDID=$(xcrun simctl list devices booted -j \
    | python3 -c 'import json,sys
d = json.load(sys.stdin)["devices"]
for runtime, devices in d.items():
    for dev in devices:
        if dev.get("state") == "Booted":
            print(dev["udid"]); raise SystemExit
' 2>/dev/null || true)
fi

if [ -z "$UDID" ]; then
  echo "no booted simulator; boot one first, e.g." >&2
  echo "  xcrun simctl boot 'iPhone 17' && open -a Simulator" >&2
  exit 1
fi

echo "== simulator =="
xcrun simctl list devices | grep -i "$UDID" || echo "  (udid $UDID)"

# --- 2. The scratch sshd, and the credentials it wrote ---------------------
DEFINES=""
if [ "$want_live" = "1" ]; then
  if sh tool/test_sshd.sh status 2>/dev/null | grep -q running; then
    echo "== scratch sshd already up =="
  else
    echo "== starting the scratch sshd =="
    sh tool/test_sshd.sh start
  fi

  KEY=/tmp/hp-sshd/user_ed25519
  if [ -f "$KEY" ]; then
    KEY_B64=$(base64 <"$KEY" | tr -d '\n')
    DEFINES="--dart-define=HP_IOS_SSH_KEY=$KEY_B64"
    DEFINES="$DEFINES --dart-define=HP_REMOTE_HOME=$HOME"
    DEFINES="$DEFINES --dart-define=HP_IOS_SSH_USER=$(id -un)"
    DEFINES="$DEFINES --dart-define=HP_IOS_SSH_PORT=${HP_TEST_SSHD_PORT:-2222}"
    echo "== live SSH group: enabled (herdr socket under $HOME) =="
    # `-S`, not `-f`: a Unix socket is not a regular file, and `-f` on one is
    # false -- which printed a warning about a daemon that was running the whole
    # time. Verified: the live group passed while this line claimed otherwise.
    if [ ! -S "$HOME/.config/herdr/herdr.sock" ]; then
      echo "   ⚠️  no herdr socket at $HOME/.config/herdr/herdr.sock" >&2
      echo "      the live tests will fail: start herdr on this machine first" >&2
    fi
  else
    echo "== live SSH group: SKIPPED (no $KEY) ==" >&2
  fi
fi

# --- 3. Run ----------------------------------------------------------------
# shellcheck disable=SC2086  # DEFINES is a list of separate flags on purpose.
flutter test integration_test/ios_device_test.dart -d "$UDID" $DEFINES
