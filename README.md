# herdr pocket

**English** · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="docs/logo.png" width="104" alt="herdr pocket">
</p>

A Flutter client for [herdr](https://herdr.dev) — a status board for the coding
agents running on your own machines, with a live terminal one tap behind each.

Android-first, with desktop builds used for development. **No Material Design**:
the interface is an Apple-style design system of our own, with an optional
Liquid Glass chrome.

<p align="center">
  <img src="docs/screenshots/board.png" width="44%" alt="The board, with an agent and the live herdr version">
  <img src="docs/screenshots/terminal.png" width="44%" alt="A live terminal on that agent's pane">
</p>

*Real screenshots of the app on an Android emulator, talking over SSH to a herdr
0.9.0 daemon on another machine. The workspace name is repainted — see
`tool/make_screenshots.sh`, which does the redaction and draws the frame.*

---

## What it does

**The board.** Every agent on every machine, grouped by what it needs. The
ordering is the whole argument: `needs you` first, everything quiet last.

**The terminal.** A real character grid for any pane — scrollback, selection and
copy, bracketed paste, and a key bar for the keys a soft keyboard cannot send.
The whole tab's split layout can be mirrored, so a pane that is 20 columns wide
on the desktop is legible on a phone.

**Files.** Browse a pane's working directory and read a file in it. Previews are
truncated rather than unbounded, and a binary file says so instead of drawing
noise. Long-press a file to download it to the phone.

**Git changes.** The pane's directory, read as a repository: staged, unstaged,
untracked and conflicted files, the ahead/behind count against upstream, and a
diff for any one of them.

**Starting an agent.** Choose a directory and one of the agents herdr reports it
can start; the app creates the workspace and starts it there. Tick *use an
isolated worktree* and it gets a fresh `git worktree` on its own branch instead —
so an agent can be turned loose on a task without it touching what you are
looking at. There is a smaller version too: put an agent into a shell pane that
is already idle, and no workspace is created at all.

**Attaching a file.** Paste a block of text, pick a photo, or take one. It is
uploaded to the machine and its path typed into the terminal — "look at this
screenshot" without needing a file manager at either end.

**Machines.** SSH hosts with credentials in the platform keystore and host keys
pinned on first use. Pairing one is a QR code: run `hdp pair` and scan it, and
there is no address, port or key to type.

**Notifications.** A local alert when an agent starts waiting on you; tapping it
opens that agent's terminal.

**Updating itself.** Settings → *Check for updates* asks GitHub for a newer
release, downloads the APK with a progress bar you can cancel (a cancelled
download keeps what arrived, and the next attempt continues from it), checks it
against the release's own `checksums.txt`, and hands it to the system installer.
Turning on *Check automatically* makes the app ask once per launch, and say so
with one line if there is something new. The download follows the phone's HTTP
proxy, so a connection that is slow without one is not slow with it.

Simplified Chinese (default) and English, with light and dark colour schemes
(the terminal takes the scheme's own sixteen colours).

---

## Running it

```sh
flutter pub get
flutter run -d macos          # development: talks to a local daemon directly
flutter run -d <android-id>   # the real target
```

### Connecting to a machine

The app does not discover machines; you add them. There are two ways in.

**Pair by QR code** (recommended) — run `hdp pair` on the machine and scan the
code it prints. That installs the phone's own key for you and fills in the
address, so there is nothing to type and no key to paste. See
[Pairing a phone](#pairing-a-phone-hdp) below.

**Or add it by hand:**

1. Open the board and tap the machines icon (top left).
2. **Add machine**: label, host, port, username.
3. Choose **Private key** and paste an OpenSSH private key, or **Password**.
4. Save. The app selects the new machine and connects.

On first connection you will be shown the machine's host key fingerprint.
Check it against the machine (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)
before trusting it. If the key later differs, the app says so loudly rather
than re-trusting quietly.

### What the machine needs

- **herdr 0.9.0 or newer**, running, with at least one agent.
- An SSH server that permits **stream-local forwarding** (the OpenSSH default).
  If it is off you get a specific message rather than a timeout, because the
  fix is one line of `sshd_config`: `AllowStreamLocalForwarding yes`.
- Nothing else, for the board, the terminal, files, git and starting agents.
  The **SFTP subsystem** is wanted only to move a whole file — downloading one
  to the phone, or attaching one to an agent. Turn the SFTP subsystem off and
  everything else still works; the app says exactly which of the two failed.

Nothing has to be installed beyond herdr itself. There is no bridge binary, no
helper script to copy over, and no port to open.

---

## How it connects

```
Flutter ──SSH──▶ direct-streamlocal channel ──▶ ~/.config/herdr/herdr.sock
```

The daemon's socket is a Unix domain socket on the user's own machine and is
never exposed to the network. The obvious way to bridge that is to run a helper
over SSH — and the iOS reference client does exactly that, which is why it
requires a **fork** of herdr that adds the bridge subcommand.

This client instead uses SSH's `direct-streamlocal@openssh.com` channel type,
which needs no helper at all, and therefore works against **stock herdr**.

That socket is also the reason files and git work the way they do: the herdr
protocol has no filesystem API and no git API, so those are asked of the
machine's **shell** over the same SSH connection — `ls -lA` to list a
directory, `head -c` to read a file, `git status --porcelain=v2` and
`git diff` for the changes page. It is the same data source a terminal
sidebar plugin would use, so the two cannot disagree about what changed.

Only *moving a whole file* uses something else, because a shell command is the
wrong tool for bytes: downloads and attachments go over **SFTP**. Building the
upload path is split the other way round — a shell `mkdir -p` for the
directory (SFTP's mkdir does not create parents) and SFTP for the bytes.

| Concern | Where |
|---|---|
| SSH transport, host keys | `lib/data/transport/ssh_socket_transport.dart` |
| Protocol framing (NDJSON, UTF-8 at line boundaries) | `lib/data/protocol/` |
| Terminal channel (`herdr terminal session control`) | `lib/data/terminal/` |
| Board state, fail-closed grouping | `lib/domain/agent/` |
| Reading a directory, a file, a repository | `lib/data/remote_fs.dart`, `lib/data/git_client.dart` |
| File transfer (SFTP) | `lib/data/remote_download.dart`, `lib/data/remote_upload.dart` |
| Design tokens, glass | `lib/ui/design/` |

`lib/domain/` is pure Dart — no Flutter — so the most consequential logic
(grouping, ordering, what counts as "I cannot read this") is testable without a
binding. Two tests enforce the project's structural rules and will fail the
build if they are broken:

- `test/architecture/no_material_test.dart` — no Material imports anywhere.
- `test/architecture/domain_purity_test.dart` — the domain layer stays pure.

---

## Testing

Three commands, three questions, in the order you would actually ask them.

### `flutter analyze` + `flutter test` — what CI runs

```sh
flutter analyze
flutter test                   # ~750 tests, ~40s
```

Everything that can be decided inside a Dart process: the domain layer
(ordering, grouping, parsing, the terminal's state machine), the data layer
against scripted transports, the widgets, and the two structural rules that must
not regress (`test/architecture/`: no Material, the domain stays pure Dart).

Most of this needs nothing. The files under `test/integration/` talk to a **real
daemon and a real SSH server** and skip themselves when there is not one, which
is right on a laptop and useless as a verdict — so CI does not take them at their
word:

### `sh tool/ci_tests.sh` — the same suite, with nothing skipped

```sh
sh tool/ci_tests.sh          # what CI runs, on your machine
```

Starts a headless herdr daemon and a throwaway SSH server if they are not already
up, runs the suite, and then **fails if anything skipped**. That last step is the
point: without it, a broken SSH transport still produces a green tick, because the
nine files that cover it simply decide they have nothing to do.

`HP_LIVE_WRITES=1 sh tool/ci_tests.sh` also runs the tests that *create* things (a
workspace, an uploaded file). Off by default, because on your machine that daemon
is your working session.

The SSH server is a **second sshd in /tmp** with its own host key and its own
`authorized_keys` (`tool/test_sshd.sh`). It deliberately does not touch your
`~/.ssh`: adding a key to someone's `authorized_keys` to run a test is changing
their security configuration for convenience.

### `patrol test` — does it still come up on a phone

```sh
flutter pub global activate patrol_cli   # once; puts `patrol` on PATH
patrol test -d emulator-5554             # or any connected device
```

**Run by hand, not in CI**, and deliberately blunt. Three smoke tests: it cold
starts, every root opens, and the first-run path (board → machines → add a
machine) gets where it is going — each asserting that nothing threw. What they
catch is the class of failure no unit test can see: a plugin that throws during
engine setup, a missing asset, a font that does not load.

They assert **structure, never a word, a colour, a size or a pixel**. Labels get
reworded, palettes get retuned, spacing gets adjusted — all of that is a judgement
made by looking at it, and a suite that hard-codes it turns every design tweak
into a test edit.

It is not in CI because booting an emulator, building the test APK and installing
two APKs costs about ten minutes. Run it before touching the app shell, the plugin
set or the fonts.

⚠️ `patrol test` **cannot** be replaced by `flutter test patrol_test/`. Those tests
are driven by Android's own instrumentation runner.

---

## Limits, stated plainly

- **The file browser reads; it does not edit.** It lists, previews and downloads.
  Editing a file on a phone keyboard is not something this is trying to be good
  at — the terminal next door is.
- **Notifications are foreground only.** They fire while the app is alive. Real
  background delivery would need something able to push to the phone, and there
  is nothing to push from: the daemon is on your machine and is reachable only
  over a connection the phone opened. This is an architectural limit, not an
  unfinished feature.
- **Stock herdr only.** Gram messaging, their push notifications and federated
  machines live in a fork and are not supported.
- **In-app updating is Android-only.** The check runs everywhere, but only
  Android has a way to hand a downloaded APK to its installer. On macOS the
  panel stops at the release page — and the macOS build is unsigned, so
  replacing it by hand is what you would be doing anyway.
- **The App Sandbox is off** on macOS. A herdr client must read a socket under
  the user's home directory and open outbound SSH connections; a sandboxed app
  can do neither.
- **ssh-agent authentication** is not implemented. Private keys and passwords
  are.

---

## Layout

```
lib/
  app/            shell, settings, routing
  data/           transport, protocol, terminal, notifications
  domain/         pure Dart: agent status, grouping, ordering
  ui/             design tokens, glass, components, pages
test/
  architecture/   structural rules, enforced rather than documented
  data/ ui/       unit tests
  integration/    tests against a live daemon and a live SSH server
patrol_test/      on-device smoke tests, run by hand (see Testing)
tool/             the scripts CI runs, runnable by hand
cli/hdp/          the host-side pairing CLI, in Go
docs/             the logo and the two screenshots above
assets/           fonts, agent marks, colour schemes
```

---

## CI and releases

| Workflow | On | Does |
|---|---|---|
| `.github/workflows/ci.yml` | every push and pull request | `flutter analyze`, and the test gate above with a real daemon and **no skipped tests** |
| `.github/workflows/release.yml` | tag `v*` | release APK (split + universal) and a macOS `.dmg`, attached to a GitHub Release |
| `.github/workflows/hdp-release.yml` | tag `hdp-v*` | the `hdp` CLI's static binaries |

## Pairing a phone: `hdp`

The app needs an SSH key installed on the machine it talks to. Doing that by
hand means generating a key, finding `authorized_keys`, and pasting a PEM into a
phone — so there is a small CLI that does it with a QR code instead:

```sh
curl -sSL https://raw.githubusercontent.com/weekitmo/herdr-pocket/main/cli/hdp/install.sh | sh
hdp pair
```

Full documentation, including what it writes and why it is safe to put a
private key in a QR code: [`cli/hdp/README.md`](cli/hdp/README.md).
