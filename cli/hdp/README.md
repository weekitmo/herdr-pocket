# hdp

Pair a phone with this machine, without a password.

`hdp pair` prints a QR code. The [Herdr Pocket](../README.md) app scans it — or
has the same string pasted in — and ends up with an SSH key installed on this
machine and a pinned host key, in about three seconds, with nothing typed.

```
$ hdp pair
  ██████████████████
  ██  ▄▄▄▄▄▄▄▄  ██       ← scan this with Herdr Pocket (recommended)
  …

   you@10.0.0.2:22 (your machine)

  If you cannot scan it, copy the whole string below and paste it into the
  app's pairing screen instead — it is the same data.

  eyJ2IjoxLCJoIjoiMTAuMC4wLjIiLCJwIjoyMiwidSI6InlvdSIsImsiOiItLS1C…

  Waiting for the phone to install its key…
```

## Install

```sh
curl -sSL https://raw.githubusercontent.com/weekitmo/herdr-pocket/main/cli/hdp/install.sh | sh
```

Downloads the release for your platform, **verifies its SHA-256 against the
checksums published with it**, and installs to `~/.local/bin` (or
`/usr/local/bin` when that is writable). It tells you what to add to `PATH` if
needed.

| Variable | Effect |
|---|---|
| `HDP_VERSION=v0.1.0` | install a specific release instead of the latest |
| `HDP_INSTALL_DIR=…` | install somewhere else |

There is deliberately **no flag to skip the checksum**. The tarball and the
checksums come from the same origin over the same TLS connection, so this does
not defend against a compromised repository — nothing delivered this way can.
It defends against a truncated or corrupted download, which is the thing that
actually happens.

### From source

```sh
go install github.com/weekitmo/herdr-pocket/cli/hdp@latest
```

## Use

```sh
hdp pair                 # print a code and wait for a phone
hdp list                 # which phones are paired with this machine
hdp unpair <token>       # remove one of them
hdp version
```

### `hdp pair` flags

| Flag | Default | |
|---|---|---|
| `--user NAME` | your username | the login the phone connects as |
| `--host ADDRESS` | guessed | the address the phone should dial |
| `--port N` | `22` | |
| `--name LABEL` | — | how this machine shows up in the app |
| `--window DUR` | `5m` | how long the code stays valid (`90s`, `5m`, …) |
| `--no-qr` | | print only the pairing string |
| `--json` | | machine-readable output, for scripts |
| `--force` | | do not ask, even when phones are already paired |

`--host` is worth knowing about. The default is guessed from this machine's own
interfaces, and the guess is printed next to the code so it can be checked; a
laptop on a tailnet usually wants its tailnet name instead of a LAN address:

```sh
hdp pair --host my-laptop.tailnet.ts.net
```

## How it works

The problem is circular: installing a key on a machine needs a working session
on that machine, and a working session needs a key. Something has to break the
circle, and the only thing that can is a channel that does not go over the
network at all.

1. `hdp pair` generates a **one-time** ed25519 key and writes exactly one line
   into `~/.ssh/authorized_keys`:

   ```
   restrict,command="/usr/local/bin/hdp __exchange '/home/you/.ssh/authorized_keys'" ssh-ed25519 AAAA… hdp-bootstrap-<token>
   ```

   `restrict` removes the pty, agent forwarding, port forwarding and X11.
   `command=` makes sshd run that program **instead of** whatever the client
   asks for. The path of the `authorized_keys` file is carried in the command so
   the two halves of pairing cannot disagree about which file to write.

2. The pairing string — host, port, user, that private key, and **this
   machine's host key fingerprint** — is rendered as a QR code and printed as
   text. Both are the same bytes.

3. The phone connects once with that key. sshd runs `hdp __exchange`, which
   reads the phone's own public key from stdin and installs it.

4. The phone connects a second time **with its own key**, to prove the key it
   just installed actually works. A pairing that only reported "appended a line"
   would save a machine that cannot connect.

5. `hdp pair` deletes its one-time line and exits.

### What the one-time key can and cannot do

It can run `hdp __exchange` and nothing else. Verified against a real sshd: a
client holding it that asks for `rm -rf /tmp/should-not-happen; id` gets the
forced command run instead, and the file is never created.

It is deleted when the phone arrives, when the window closes, and on **Ctrl-C** —
`defer` does not run for a signal, so the exit paths that matter have an explicit
handler. A run that was killed outright (SIGKILL, a closed terminal, a power
cut) leaves its line behind, and the next `hdp pair` sweeps every
`hdp-bootstrap-*` line before adding its own, so they cannot accumulate.

The residual risk is a photograph of the screen during the window. That buys the
holder the ability to install a key of their own, for as long as the window is
open — which is why the window is short by default and stated on screen.

### Why the fingerprint is in the code

It makes the QR an **authenticated** channel rather than a convenient one. The
app pins the host key from the string instead of asking the user to compare a
fingerprint by eye — a step people skip, and which therefore protects nobody.

It is read by asking the running server (`ssh-keyscan`), falling back to
`/etc/ssh/ssh_host_*.pub` only when the server is not up. Those files are the
*defaults*: a machine with its own `HostKey` line — a second sshd on a spare
port, or one that has rotated its keys — serves something else, and reading the
files there pins a fingerprint the app will then report as a **host key
mismatch** on a machine nobody attacked.

## Why the code is this size

A QR code read off a terminal by a phone camera has to fit two budgets at once:
the terminal's columns, and the camera's ability to resolve individual modules.

Measured, the first version was **93 columns wide** — which does not fit a
default 80-column terminal at all, and a terminal that wraps it turns a QR code
into noise. Two independent things were making it that big:

- one character was drawn per module and one LINE per module, instead of two
  rows of modules per line;
- the pairing string carried a whole OpenSSH **private key file** (about 400
  characters), which is mostly base64 wrapping around 32 bytes that cannot be
  recomputed from anything else.

The string now carries the 32-byte **seed**, and the app rebuilds the key file
from it. Drawn in half blocks, the code is **57 columns by 29 lines** — it fits
anywhere and scans at a comfortable distance. `openssh-key-v1` is a container
around exactly that seed, so nothing is lost.

## What gets changed on this machine

Exactly one file, and only for the length of a pairing:

| | |
|---|---|
| `~/.ssh/authorized_keys` | one `restrict,command=…` line while pairing; the phone's own key after |
| `~/.ssh` permissions | tightened to `0700` / `0600` if they were wider — sshd's `StrictModes` refuses an `authorized_keys` that is group- or world-writable, and the failure it causes reads as an authentication problem rather than a permission one |

The path is resolved by asking `sshd -T`, not assumed: a machine with its own
`AuthorizedKeysFile` would otherwise be given a key in a file sshd never reads.

Nothing else is touched. No daemon, no listening port, no `sshd_config` change,
no service.

## Troubleshooting

**The phone cannot reach the machine.** The address next to the code is a guess.
Re-run with `--host`.

**`hdp: could not work out this machine's host key`.** No SSH client will
connect without it. `ssh-keyscan` needs the sshd to be running; the fallback
needs `/etc/ssh/ssh_host_*_pub` to be readable.

**Pairing times out.** The window expired, or `hdp` is not where the forced
command says it is. The command contains an **absolute path** — re-running
`hdp pair` after moving or reinstalling the binary is required, and `hdp list`
plus a fresh pairing is the fix.

**The app says the host key changed.** The fingerprint in the code is not the
one the server presented. Most often the code is stale; occasionally it is what
it sounds like.

**"This pairing code has expired" on the phone, right after running `hdp pair`.**
The code has not necessarily expired — that sentence covers every authentication
failure, and the app now prints the server's own words underneath it, which is
usually enough to tell them apart. The three that happen:

- **Another `hdp pair` is still running.** Two runs coexist correctly (each code
  has its own token), and the second one says so. But a code is deleted as soon
  as its own run finishes, so a code you scanned after that run exited really is
  gone. Re-run and scan the new one.
- **The host's sshd does not read the file `hdp` wrote.** Run
  `hdp pair --json` and check the `authorized keys file` line it prints — that
  path comes from `sshd -T`, so if it is not the file your server actually uses,
  something is overriding `AuthorizedKeysFile` in a way `sshd -T` cannot see.
- **`StrictModes` refused the file.** sshd rejects an `authorized_keys` inside a
  group- or world-writable directory, and says so in its log
  (`Authentication refused: bad ownership or modes for directory …`). `hdp` sets
  `~/.ssh` to `0700` and the file to `0600`; a home directory on a shared volume
  can still fail this.

**Paired phones stopped working after an update.** The forced command in each
phone's line names the absolute path of the binary. If it moved, re-pair — or
check `hdp list` and `hdp unpair` to see what is left.

## Development

```sh
cd cli/hdp
go test ./...            # unit tests: payload, authorized_keys, exchange
sh install_test.sh       # runs install.sh for real against a local server
```

`install_test.sh` is not a linter. It builds a binary, packages it the way the
release workflow does, serves it over HTTP, and then runs the installer **the
way `curl | sh` does** — `sh < install.sh`, so stdin is the script. That is the
only way to catch the mistake that matters there: a stray read of stdin swallows
the rest of the script and the install stops halfway, silently, with exit 0.

Releases are cut by pushing a tag:

```sh
git tag hdp-v0.1.0 && git push origin hdp-v0.1.0
```

`.github/workflows/hdp-release.yml` builds `darwin`/`linux` × `arm64`/`amd64`,
stamps the version in, and publishes the tarballs with `checksums.txt`.
