#!/bin/sh
# A throwaway SSH server for verifying the `direct-streamlocal` transport.
#
# WHY NOT JUST USE THE MACHINE'S OWN sshd: doing so means adding a key to the
# developer's `authorized_keys` and clearing a stale host key out of their
# `known_hosts`. Both are changes to someone's security configuration, made to
# run a test. This starts a second sshd in /tmp with its own host key, its own
# authorised key and its own pid file, so the test touches nothing that belongs
# to the user.
#
# Usage:
#   sh tool/test_sshd.sh start
#   sh tool/test_sshd.sh stop
#   sh tool/test_sshd.sh status
#
# Port 2222 on 127.0.0.1 only. Stream-local forwarding is explicitly enabled,
# because that is the capability under test.
set -eu

DIR="${HP_TEST_SSHD_DIR:-/tmp/hp-sshd}"
PORT="${HP_TEST_SSHD_PORT:-2222}"
CONFIG="$DIR/sshd_config"
PIDFILE="$DIR/sshd.pid"

# Set to 1 to generate the config WITH an sftp subsystem.
#
# OFF BY DEFAULT, and the default is the interesting one: the generated config
# has no `Subsystem` line at all, which is exactly what a hardened sshd looks
# like. `client.sftp()` against it does NOT throw — it hangs forever — so having
# a server in that state is the only way to test the detection path. Set this to
# 1 for the same server with one line added, and the difference between the two
# IS the measurement. See tool/probe_sftp.dart.
SFTP="${HP_TEST_SSHD_SFTP:-0}"

# WHERE THE BINARIES ARE, which is the one thing that differs between the
# developer's machine and CI. macOS ships both in /usr/libexec; Debian and
# Ubuntu put sshd in /usr/sbin (already on PATH for root) and the SFTP subsystem
# in /usr/lib/openssh. Hard-coding either layout is how this script worked
# locally and failed on the first CI run — which is the failure mode it exists to
# prevent in the code under test.
SSHD="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
SFTP_SERVER=""
for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server; do
  if [ -x "$candidate" ]; then
    SFTP_SERVER="$candidate"
    break
  fi
done

# sshd needs root for privilege separation. On a laptop it usually works without
# (the login user is the same as the one running it); in a container or on a
# runner it sometimes does not. `sudo -n` is used only when it is already
# passwordless, so this never stops to ask a question.
maybe_sudo() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    return 127
  fi
}

run_sshd() {
  # shellcheck disable=SC2086
  "$SSHD" -f "$CONFIG" -E "$DIR/sshd.log"
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE")) on port $PORT"
    return 0
  fi

  command -v ssh-keygen >/dev/null 2>&1 || {
    echo "ssh-keygen is not on PATH; install openssh-client" >&2
    exit 1
  }

  rm -rf "$DIR"
  mkdir -p "$DIR"
  chmod 700 "$DIR"

  ssh-keygen -q -t ed25519 -f "$DIR/host_ed25519" -N '' -C hp-test-host
  ssh-keygen -q -t ed25519 -f "$DIR/user_ed25519" -N '' -C hp-test-user
  cp "$DIR/user_ed25519.pub" "$DIR/authorized_keys"
  chmod 600 "$DIR/authorized_keys"

  cat > "$CONFIG" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
AuthorizedKeysFile $DIR/authorized_keys
PidFile $PIDFILE
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PermitRootLogin no
LogLevel VERBOSE
EOF

  if [ "$SFTP" = "1" ]; then
    [ -n "$SFTP_SERVER" ] || {
      echo "no sftp-server binary found; looked in /usr/libexec, /usr/lib/openssh, /usr/lib/ssh" >&2
      exit 1
    }
    printf 'Subsystem sftp %s\n' "$SFTP_SERVER" >> "$CONFIG"
  fi

  run_sshd || {
    echo "  sshd refused to run as $(id -un); retrying at the same config" >&2
    maybe_sudo "$SSHD" -f "$CONFIG" -E "$DIR/sshd.log" || true
  }
  sleep 1

  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "test sshd listening on 127.0.0.1:$PORT (pid $(cat "$PIDFILE"))"
    echo "  host key: $DIR/host_ed25519"
    echo "  user key: $DIR/user_ed25519"
  else
    echo "failed to start; see $DIR/sshd.log" >&2
    tail -5 "$DIR/sshd.log" >&2 || true
    exit 1
  fi
}

stop() {
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null ||
        maybe_sudo kill "$pid" 2>/dev/null ||
        true
      sleep 1
      echo "stopped (pid $pid)"
    else
      echo "not running"
    fi
  else
    echo "no pid file"
  fi
  rm -rf "$DIR" 2>/dev/null || maybe_sudo rm -rf "$DIR" || true
}

status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PIDFILE")) on port $PORT"
  else
    echo "not running"
  fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
