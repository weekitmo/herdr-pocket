#!/bin/sh
# Runs install.sh for real, against a local HTTP server that pretends to be the
# GitHub releases page.
#
# WHY THIS EXISTS. `install.sh` is the one file in this project whose failure
# mode is invisible: a script that only ever gets `sh -n`'d parses fine and then
# eats its own stdin, or installs a binary that will not run, or reports success
# after a checksum mismatch. None of those show up until a user on a fresh
# machine runs the one-liner from the README.
#
#     sh cli/hdp/install_test.sh
#
# It builds a real binary for this machine, packages it the way the release
# workflow does, serves it, and then exercises:
#
#   1. the PIPED path          — `sh < install.sh`, which is what `curl | sh`
#                                actually is, and where a stray stdin read
#                                silently truncates the script
#   2. a corrupt download      — the checksum must stop it
#   3. a missing checksum      — must stop it rather than skip verification
#   4. an unsupported platform — must explain, not fail obscurely
#
# POSIX sh, like the script it tests.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hdp-installtest.XXXXXX")
port=${HDP_TEST_PORT:-8731}

cleanup() {
    [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP

fail() { printf 'install_test: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok  %s\n' "$*"; }

# --------------------------------------------------------------- fixtures ---

case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *)      fail "this test only runs on macOS or Linux" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *)             arch=$(uname -m) ;;
esac

version=v0.0.0-test
bare=${version#v}
asset="hdp_${bare}_${os}_${arch}.tar.gz"

printf 'building a test binary…\n'
( cd "$here" && go build -o "$work/hdp" . ) || fail "go build failed"

mkdir -p "$work/releases/download/$version"
( cd "$work" && tar -czf "releases/download/$version/$asset" hdp )
( cd "$work/releases/download/$version" && \
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$asset" > checksums.txt
  else shasum -a 256 "$asset" > checksums.txt; fi )

printf 'serving %s on 127.0.0.1:%s\n\n' "$work/releases" "$port"
( cd "$work" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
server_pid=$!

# Wait for it rather than sleeping a fixed amount: a fixed sleep is either
# flaky on a loaded machine or slower than it needs to be on an idle one.
i=0
while [ "$i" -lt 50 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/releases/" 2>/dev/null; then break; fi
    i=$((i + 1))
    sleep 0.1
done
[ "$i" -lt 50 ] || fail "the test server never came up"

export HDP_RELEASES_URL="http://127.0.0.1:$port/releases"
export HDP_VERSION="$version"

# ------------------------------------------------------- 1. the piped path ---

printf '1. piped install (this is what `curl … | sh` is)\n'
target="$work/installed"
mkdir -p "$target"
# `< install.sh`, not `sh install.sh`: stdin is the script, exactly as it is
# under curl. If anything inside reads stdin, this is where it breaks.
if HDP_INSTALL_DIR="$target" sh < "$here/install.sh" > "$work/1.out" 2>&1; then
    pass "installer exited 0"
else
    cat "$work/1.out" >&2
    fail "piped install failed — see the output above"
fi

[ -x "$target/hdp" ] || fail "nothing was installed to $target"
pass "binary landed at $target/hdp"

got=$("$target/hdp" version)
case "$got" in
    hdp\ *) pass "installed binary runs: $got" ;;
    *)      fail "the installed binary did not run: $got" ;;
esac

# The PATH advice is the one message a fresh machine actually needs.
grep -q "PATH" "$work/1.out" || fail "no PATH advice was printed"
pass "PATH advice printed"

# ------------------------------------------------ 2. a corrupt download ---

printf '\n2. a corrupted download must be refused\n'
printf 'junk' >> "$work/releases/download/$version/$asset"
if HDP_INSTALL_DIR="$work/should-not-exist" sh < "$here/install.sh" > "$work/2.out" 2>&1; then
    fail "a corrupt tarball was INSTALLED — the checksum did not run"
fi
grep -qi "checksum" "$work/2.out" || { cat "$work/2.out" >&2; fail "the failure did not mention the checksum"; }
[ -e "$work/should-not-exist/hdp" ] && fail "a binary was left behind after a failed verification"
pass "refused, and the message says why"

# ------------------------------------------------ 3. a missing checksum ---

printf '\n3. a release with no checksums must be refused\n'
cp "$work/releases/download/$version/checksums.txt" "$work/checksums.bak"
rm "$work/releases/download/$version/checksums.txt"
if HDP_INSTALL_DIR="$work/should-not-exist" sh < "$here/install.sh" > "$work/3.out" 2>&1; then
    fail "the installer proceeded WITHOUT a checksum file"
fi
pass "refused rather than skipping verification"
mv "$work/checksums.bak" "$work/releases/download/$version/checksums.txt"

# -------------------------------------------- 4. an unsupported platform ---

printf '\n4. an unsupported release must explain itself\n'
if HDP_VERSION="$version-nope" HDP_INSTALL_DIR="$work/nope" sh < "$here/install.sh" > "$work/4.out" 2>&1; then
    fail "a missing release was reported as a successful install"
fi
grep -qi "could not download\|does not exist\|has a build" "$work/4.out" \
    || { cat "$work/4.out" >&2; fail "the failure was not explained"; }
pass "explained, with a next step"

printf '\nall install tests passed\n'
