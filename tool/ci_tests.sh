#!/bin/sh
#
# BASH, NOT `sh` — and it re-executes itself to get there. The one thing this
# script cannot do without is `set -o pipefail`: the suite's output goes through
# `tee` so the log survives the step, and without pipefail the pipeline reports
# TEE's status (always 0), so a red suite would print PASS.
#
# `sh` is not enough, and on Debian and Ubuntu it is dash. dash has no
# pipefail, and an unknown `set -o` option does not return non-zero — it KILLS
# THE SHELL with status 2. `set -o pipefail 2>/dev/null || true` does not catch
# that, because there is no shell left to run the `||`. Found on the first CI
# run: the step died between "== flutter test ==" and the first line of output,
# having printed nothing that pointed at a shell option.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# The test gate: exactly what CI runs, runnable on a laptop.
#
# WHY A SCRIPT AND NOT THE YAML. The last step of this gate is "nothing was
# skipped", and a rule like that is worth nothing if the only machine that ever
# executes it is a rented one. Here it is, one command, with the same failure
# message.
#
# WHAT IT ADDS TO `flutter test`:
#
#   1. a REAL herdr daemon, because nine test files under test/integration/
#      skip themselves without one. On a laptop that is correct — the daemon is
#      somebody's working session. As a CI verdict it is a lie, because the SSH
#      transport, the terminal framing and the socket protocol are the parts
#      most likely to break and the parts nothing else covers.
#   2. a THROWAWAY sshd (`tool/test_sshd.sh`), for the same reason.
#   3. a failure if anything skipped anyway.
#
# Usage:
#   sh tool/ci_tests.sh                 # the gate
#   HP_LIVE_WRITES=1 sh tool/ci_tests.sh   # also run the tests that CREATE things
#   sh tool/ci_tests.sh test/data        # narrower path, for a quick loop
#
# Requirements: `flutter` on PATH, `herdr` on PATH (or already running), and
# bash. `tool/test_sshd.sh` needs `sshd` and `ssh-keygen`.
#
# IT DOES NOT TOUCH THE DEVELOPER'S OWN ~/.ssh: see tool/test_sshd.sh, which
# starts a second sshd in /tmp with its own host key and its own keys.
# `-o pipefail` is load-bearing, not hygiene: the suite's output is piped through
# `tee`, and without it the pipeline reports tee's status — always 0 — so a red
# suite would end this script with PASS. Guaranteed to work because of the
# re-exec above.
set -euo pipefail

cd "$(dirname "$0")/.."

LOG="${TMPDIR:-/tmp}/herdr-pocket-ci-tests.log"

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------------ daemon --
#
# STARTED ONLY IF THERE IS NOT ONE. A daemon may already be running because the
# developer is using herdr, and stopping or restarting it to run a test would
# be rearranging somebody's terminal panes to check an assertion.

SOCKET="${HERDR_SOCKET:-$HOME/.config/herdr/herdr.sock}"

say "herdr daemon"
if [ -S "$SOCKET" ]; then
  echo "  already running at $SOCKET"
else
  command -v herdr >/dev/null 2>&1 ||
    die "no daemon at $SOCKET and no 'herdr' on PATH to start one.
  Local:  install it — curl -fsSL https://herdr.dev/install.sh | sh
  CI:     the workflow installs it before calling this script."

  echo "  starting a headless daemon..."
  nohup herdr server >"${TMPDIR:-/tmp}/herdr-pocket-daemon.log" 2>&1 &
  for _ in $(seq 1 60); do
    [ -S "$SOCKET" ] && break
    sleep 1
  done
  [ -S "$SOCKET" ] || {
    tail -20 "${TMPDIR:-/tmp}/herdr-pocket-daemon.log" >&2 || true
    die "herdr never created $SOCKET"
  }
  echo "  listening at $SOCKET"
fi

# -------------------------------------------------------------------- sshd --
#
# 2222 is the port the transport tests expect. `file_transfer_test.dart` starts
# its own two servers (2223, 2224) by calling the same script.

say "throwaway sshd"
sh tool/test_sshd.sh start

# ------------------------------------------------------------------- tests --

say "flutter test"

if [ "${HP_LIVE_WRITES:-0}" = "1" ]; then
  echo "  (HP_LIVE_WRITES=1: the create/upload paths run against the daemon too)"
  HERDR_POCKET_LIVE_WRITES=1 flutter test --reporter expanded "$@" 2>&1 | tee "$LOG"
else
  echo "  (set HP_LIVE_WRITES=1 to also exercise the tests that create workspaces)"
  flutter test --reporter expanded "$@" 2>&1 | tee "$LOG"
fi

# ------------------------------------------------------------- no skips -----
#
# THE LAST LINE IS THE VERDICT. Flutter's expanded reporter ends with
# `+<passed> ~<skipped>:` and omits `~` entirely when nothing was skipped, so a
# non-zero count here means a test looked around, found nothing to do, and said
# so — which is the one outcome this whole script exists to prevent.
#
# ONE EXCEPTION, AND IT IS THE OPT-IN ONE. Without HP_LIVE_WRITES the three
# tests in `live_writes_test.dart` skip themselves, because they create a
# workspace on a daemon that on a laptop is somebody's working session. That
# number is allowed here and nowhere else: `~3` off, `~1` or `~4` is a
# different test that has quietly stopped running, and it fails.

say "nothing was skipped"
SUMMARY="$(tail -1 "$LOG")"
echo "  $SUMMARY"

EXPECTED_SKIPS=3
if [ "${HP_LIVE_WRITES:-0}" = "1" ]; then
  EXPECTED_SKIPS=0
fi

case "$SUMMARY" in
  *"~0:"*)
    if [ "$EXPECTED_SKIPS" -ne 0 ]; then
      echo "  (the three live-write tests ran as well — that is more than expected)"
    fi
    ;;
  *"~"*)
    SKIPPED="$(printf '%s' "$SUMMARY" | sed -n 's/.*~\([0-9][0-9]*\):.*/\1/p')"
    if [ "$SKIPPED" = "$EXPECTED_SKIPS" ]; then
      if [ "$EXPECTED_SKIPS" -ne 0 ]; then
        echo "  the $EXPECTED_SKIPS live-write tests are off; HP_LIVE_WRITES=1 runs them."
        echo "  (CI sets it — its daemon was started a minute ago and dies with the runner.)"
      fi
    else
      echo "" >&2
      echo "Skipped tests, in a run that installed a daemon and an sshd for them:" >&2
      grep -E '^[0-9:]+ \+[0-9]+ ~[0-9]+' "$LOG" >&2 | head -40 || true
      die "$SKIPPED tests skipped, expected $EXPECTED_SKIPS — a skip that is not \
the documented opt-in is a test that did not run"
    fi
    ;;
  *) : ;;
esac

printf '\n\033[1m%s\033[0m\n' "PASS: the suite ran in full, against a real daemon and a real sshd"
