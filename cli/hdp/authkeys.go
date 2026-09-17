// Package main — the authorized_keys half of pairing.
//
// This file is the security-critical one. It writes a line into a file that
// decides who may log in, it must never widen anyone's access by accident, and
// the thing it writes must be removable by exactly the same string it used to
// add it — because a bootstrap key that outlives its pairing window is a
// credential nobody remembers issuing.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The comment that marks our lines, so the reader can find them again without
// guessing. `hdp list` and `hdp unpair` work off these prefixes.
const bootstrapMarker = "hdp-bootstrap-"

// The comment the PHONE's own key carries, which is what `pair` watches for.
const clientMarker = "hdp-pocket"

// AuthorizedKeys is one machine's authorized_keys file and the state it was
// found in.
type AuthorizedKeys struct {
	Path string
}

// ResolveAuthorizedKeys finds where this machine actually keeps its keys.
//
// ASKED, NOT ASSUMED. `~/.ssh/authorized_keys` is only the default: sshd
// happily runs with `AuthorizedKeysFile .ssh/authorized_keys2` or a templated
// path, and a `hdp` that writes to the default on such a machine would report
// success while the key it wrote is never read. `sshd -T` prints the effective
// configuration, which is the only place that answer exists.
func ResolveAuthorizedKeys() (*AuthorizedKeys, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("could not find your home directory: %w", err)
	}

	path := ""
	// -T dumps the effective config. It needs to be run as a user who may read
	// the configuration; if it fails we fall back rather than refusing, because
	// on a machine where sshd is not installed at all the default is still the
	// only sensible answer.
	if out, err := exec.Command("sshd", "-T").Output(); err == nil {
		path = authorizedKeysFileFrom(string(out))
	}
	if path == "" {
		path = filepath.Join(home, ".ssh", "authorized_keys")
	}

	if !filepath.IsAbs(path) {
		// sshd resolves a relative AuthorizedKeysFile against the user's home.
		path = filepath.Join(home, path)
	}
	return &AuthorizedKeys{Path: path}, nil
}

// authorizedKeysFileFrom pulls the first `authorizedkeysfile` line out of an
// `sshd -T` dump.
//
// The value may be several whitespace-separated paths, in which case sshd tries
// each in turn and the first that exists wins. We write to the FIRST one, which
// is the one sshd will read.
func authorizedKeysFileFrom(dump string) string {
	scanner := bufio.NewScanner(strings.NewReader(dump))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if strings.EqualFold(fields[0], "authorizedkeysfile") {
			return fields[1]
		}
	}
	return ""
}

// Lines reads the file, or returns nothing if it does not exist yet.
func (a *AuthorizedKeys) Lines() ([]string, error) {
	data, err := os.ReadFile(a.Path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("could not read %s: %w", a.Path, err)
	}
	// A trailing newline is not an empty line, and keeping it would make every
	// rewrite grow the file by one blank line per run.
	text := strings.TrimRight(string(data), "\n")
	if text == "" {
		return nil, nil
	}
	return strings.Split(text, "\n"), nil
}

// EnsureWritableDirectory creates ~/.ssh and fixes its permissions.
//
// MUST RUN BEFORE ANY WRITE, and it is not tidiness. sshd refuses to read an
// authorized_keys whose directory or file is group- or world-writable
// (`StrictModes`, on by default), and what the user sees in that case is
// "pairing succeeded" followed by an authentication failure — a symptom that
// points at the key rather than at the permissions, which is the wrong place
// to look.
func (a *AuthorizedKeys) EnsureWritableDirectory() error {
	dir := filepath.Dir(a.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("could not create %s: %w", dir, err)
	}
	// Only directories we might have just created, and only narrowing: a user
	// who deliberately opened their own ~/.ssh to 0755 to share a key is not
	// someone to correct silently. 0700 is what sshd requires and what every
	// tool writes.
	if info, err := os.Stat(dir); err == nil && info.Mode().Perm()&0o077 != 0 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("could not tighten %s: %w", dir, err)
		}
	}
	return nil
}

// Add appends lines, creating the file with 0600 if needed.
func (a *AuthorizedKeys) Add(lines ...string) error {
	if err := a.EnsureWritableDirectory(); err != nil {
		return err
	}
	existing, err := a.Lines()
	if err != nil {
		return err
	}
	existing = append(existing, lines...)
	return a.write(existing)
}

// RemoveMatching drops every line satisfying match, and reports how many went.
func (a *AuthorizedKeys) RemoveMatching(match func(string) bool) (int, error) {
	existing, err := a.Lines()
	if err != nil {
		return 0, err
	}
	kept := existing[:0:0]
	removed := 0
	for _, line := range existing {
		if match(line) {
			removed++
			continue
		}
		kept = append(kept, line)
	}
	if removed == 0 {
		return 0, nil
	}
	if err := a.write(kept); err != nil {
		return 0, err
	}
	return removed, nil
}

// write replaces the file atomically, with the mode sshd demands.
//
// Written to a sibling and renamed, so an interrupted run cannot leave a
// truncated authorized_keys behind — the failure mode of an in-place rewrite
// here is "the user can no longer log in", which is a catastrophic outcome for
// a cosmetic interruption.
func (a *AuthorizedKeys) write(lines []string) error {
	if err := a.EnsureWritableDirectory(); err != nil {
		return err
	}

	body := ""
	if len(lines) > 0 {
		body = strings.Join(lines, "\n") + "\n"
	}

	tmp, err := os.CreateTemp(filepath.Dir(a.Path), ".authorized_keys.*")
	if err != nil {
		return fmt.Errorf("could not stage a write to %s: %w", a.Path, err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once the rename has happened

	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("could not set permissions: %w", err)
	}
	if _, err := tmp.WriteString(body); err != nil {
		tmp.Close()
		return fmt.Errorf("could not write %s: %w", a.Path, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("could not write %s: %w", a.Path, err)
	}
	if err := os.Rename(tmpName, a.Path); err != nil {
		return fmt.Errorf("could not replace %s: %w", a.Path, err)
	}
	return nil
}

// BootstrapLine builds the authorized_keys entry for a pairing.
//
// SIX PARTS, and each one is load-bearing:
//
//  1. `restrict` — no pty, no agent forwarding, no port forwarding, no X11, no
//     user rc. Without it the bootstrap key is a login key, and the whole
//     argument for putting a private key in a QR code collapses.
//
//  2. `command=` — the forced command. sshd runs this INSTEAD of whatever the
//     client asked for; verified by hand against a real sshd, where requesting
//     `rm -rf /tmp/should-not-happen; id` ran the forced command and left no
//     file behind.
//
//  3. An ABSOLUTE path to this binary. A non-interactive shell has a PATH that
//     usually does not include wherever hdp was installed, so `command="hdp
//     exchange"` works in the developer's shell and fails everywhere else.
//
//  4. THE AUTHORIZED_KEYS PATH, as an argument.
//
//     This one was learned the hard way. The forced command runs inside sshd's
//     process, where `HOME` comes from the passwd entry — so if the two halves
//     ever disagree about where the file is, pairing REPORTS SUCCESS AND
//     INSTALLS THE KEY SOMEWHERE ELSE. Measured: a `hdp pair` run with a
//     different HOME appended the phone's key to the developer's real
//     `~/.ssh/authorized_keys` while the pairing looked like it had worked.
//
//     Passing the resolved path makes the two halves agree by construction,
//     and it is not an injection risk: the value is written by hdp into the
//     user's own authorized_keys, and the network peer has no way to influence
//     it. What the peer sends is only ever a public key, and only ever on
//     stdin, after sshd has already accepted this line.
//
//  5. THE TOKEN, as the forced command's second argument. It names the ONE line
//     this invocation belongs to, which is what lets `__exchange` delete that
//     line the moment the phone's key is in — the credential dying at the
//     instant it is used, rather than when a parent process notices. It is also
//     the only signal that distinguishes "this phone paired" from "nothing
//     happened" when the SAME phone re-pairs: an unchanged key line leaves the
//     file looking exactly as it did before.
//
//  6. The same token as a per-run comment, which is the handle `hdp unpair`,
//     the parent's cleanup, and a later `hdp pair`'s stale sweep find it by.
func BootstrapLine(pubKeyLine, binaryPath, keysPath, token string) string {
	if err := checkForcedCommandPath(binaryPath); err != nil {
		panic("hdp: refusing to write a forced command: " + err.Error())
	}
	if err := checkForcedCommandPath(keysPath); err != nil {
		panic("hdp: refusing to write a forced command: " + err.Error())
	}
	if err := checkForcedCommandToken(token); err != nil {
		panic("hdp: refusing to write a forced command: " + err.Error())
	}
	return fmt.Sprintf(
		`restrict,command="%s __exchange %s %s" %s %s%s`,
		binaryPath, shellSingleQuote(keysPath), token, pubKeyLine,
		bootstrapMarker, token)
}

// checkForcedCommandToken refuses a token that cannot be embedded safely.
//
// The token is a decimal clock reading and is generated here, so this can only
// fail if something else starts calling this function with a value a phone sent
// — which is precisely the mistake worth failing loudly on, because the token
// goes inside `command="…"` where a space or a quote would add a shell word.
func checkForcedCommandToken(token string) error {
	if token == "" {
		return errors.New("the token is empty")
	}
	for _, r := range token {
		if r < '0' || r > '9' {
			return fmt.Errorf("%q is not a decimal token", token)
		}
	}
	return nil
}

// checkForcedCommandPath refuses a path that cannot be embedded safely.
//
// ONLY quotes and newlines are a problem, and refusing them is the same
// discipline `quoteRemotePath` applies on the app side: a value that cannot be
// represented in the target syntax is not a value to escape creatively, it is a
// value to reject. No real authorized_keys path contains any of these, so the
// failure is theoretical — which is exactly why it should be loud rather than
// emitted as a shell word nobody can reason about.
func checkForcedCommandPath(path string) error {
	if path == "" {
		return errors.New("the path is empty")
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("%q is not absolute", path)
	}
	if strings.ContainsAny(path, "\"'\n\r\x00") {
		return fmt.Errorf("%q contains a quote or a control character", path)
	}
	return nil
}

// shellSingleQuote wraps a value so `sh -c` hands it back unchanged.
//
// The path has already been checked for quotes, so the simple form is correct —
// and the check is why a second escaping rule does not have to be reasoned
// about here.
func shellSingleQuote(s string) string { return "'" + s + "'" }
