// Command hdp pairs a phone with this machine, without a password.
//
// # The shape of the problem
//
// Installing a key on a machine needs a working session on that machine, and a
// working session needs a key. Something has to break the circle, and the only
// thing that can is a channel that does not go over the network at all.
//
// `hdp pair` puts a ONE-TIME, FORCED-COMMAND key into authorized_keys and
// renders it — with the host, port, user and the server's own host key
// fingerprint — as a QR code on the terminal. The phone scans it (or has the
// same string pasted in), connects once with that key, and sshd runs one
// command with it: `hdp __exchange`, which reads the phone's real public key
// from stdin and installs it.
//
// # What it therefore does NOT need
//
//   - no password, ever
//   - no listening port (the phone dials the host, not the other way round)
//   - no change to sshd_config
//   - no working LAN between the two for anything except the SSH connection
//     itself — a host reached over a tailnet or a forwarded port pairs fine,
//     because the only thing that has to be local is the eye looking at the
//     code
//
// # Why the bootstrap key is safe to put in a QR code
//
// It is `restrict`ed and it is `command=`ed, so it can run exactly one program
// and nothing else — verified against a real sshd, where asking it to run
// `rm -rf /tmp/should-not-happen; id` ran the forced command instead and left no
// file behind. It is deleted the moment the phone's own key appears, or when the
// window closes. The residual risk is a photograph of the screen during that
// window, which buys the holder the ability to install a key of their own — and
// the window is short by construction and printed on screen.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// version is stamped in at release time.
//
// `-ldflags "-X main.version=v0.1.0"` and not a constant, because the value
// that matters is the one baked into a released binary: a `hdp version` that
// reports what the source said at HEAD tells a user with a problem nothing
// about the binary they are actually running.
var version = "dev"

// The default pairing window.
//
// Long enough to find the phone, unlock it, open the app and point a camera;
// short enough that a photograph of the screen stops mattering. It is printed on
// screen rather than hidden, and adjustable, because the honest thing to do with
// a security parameter is to state it.
const defaultWindow = 5 * time.Minute

// / The shortest a leftover can be and still be spared the sweep.
// /
// / A `hdp pair` never waits longer than its window, and the window is on screen
// / and adjustable — so anything older than the window plus a margin cannot
// / belong to a run that is still waiting. The floor keeps a short `--window 30s`
// / from making the sweep trigger-happy on a code someone is still walking
// / across the room to scan.
const minStaleAfter = 15 * time.Minute

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "pair":
		os.Exit(runPair(os.Args[2:]))
	case "unpair":
		os.Exit(runUnpair(os.Args[2:]))
	case "list":
		os.Exit(runList(os.Args[2:]))
	case "__exchange":
		// Not advertised and not meant to be run by hand. sshd invokes it as
		// the forced command of a bootstrap key, with the SSH channel as stdin
		// and stdout.
		os.Exit(runExchange(os.Args[2:], os.Stdin, os.Stdout, os.Stderr))
	case "version", "--version", "-v":
		fmt.Printf("hdp %s (protocol %d)\n", version, PairingVersion)
	case "help", "--help", "-h":
		usage(os.Stdout)
	default:
		fmt.Fprintf(os.Stderr, "hdp: unknown command %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `hdp — pair Herdr Pocket with this machine, without a password

  hdp pair [flags]     Print a QR code and a pairing string, then wait
  hdp list             Show the phones currently paired with this machine
  hdp unpair <token>   Remove one of them
  hdp version

pair flags:
  --user NAME      login name to connect as (default: your username)
  --host ADDRESS   address the phone should dial (default: guessed, see below)
  --port N         SSH port (default: 22)
  --name LABEL     how this machine appears in the app, e.g. "Mac mini"
  --window DUR     how long the code stays valid, e.g. 90s, 5m (default: 5m)
  --no-qr          print only the pairing string
  --json           print the pairing string as JSON
  --force          do not ask, even when phones are already paired, for scripts

Nothing needs installing on this machine beyond hdp itself, and no sshd
setting is changed.
`)
}

func runPair(args []string) int {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var (
		user   = fs.String("user", "", "login name")
		host   = fs.String("host", "", "address the phone should dial")
		port   = fs.Int("port", 22, "SSH port")
		name   = fs.String("name", "", "label for the app")
		window = fs.Duration("window", defaultWindow, "how long the code stays valid")
		noQR   = fs.Bool("no-qr", false, "print only the pairing string")
		asJSON = fs.Bool("json", false, "print the pairing string as JSON")
		force  = fs.Bool("force", false,
			"pair without asking, even when phones are already paired")
	)

	if err := fs.Parse(args); err != nil {
		return 2
	}

	resolvedUser := *user
	if resolvedUser == "" {
		var err error
		resolvedUser, err = CurrentUser()
		if err != nil {
			fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
			return 1
		}
	}

	// The addresses, with the flag overriding the guess. Printed as a hint
	// rather than silently used, because "the phone cannot reach it" is the one
	// failure a user can fix in five seconds if they are told what to type.
	candidates := CandidateHosts()
	resolvedHost := *host
	if resolvedHost == "" {
		if len(candidates) == 0 {
			fmt.Fprintln(os.Stderr,
				"hdp: could not guess an address for this machine; pass --host")
			return 1
		}
		resolvedHost = candidates[0]
	}

	fingerprint, err := HostKeyFingerprint("127.0.0.1", *port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	privatePEM, pubLine, err := NewBootstrapKey()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	keys, err := ResolveAuthorizedKeys()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	// The forced command needs an ABSOLUTE path to this binary, because a
	// non-interactive SSH session's PATH rarely contains wherever it was
	// installed — the failure being that the line looks right and the pairing
	// silently hangs.
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: could not locate my own binary: %v\n", err)
		return 1
	}
	self, err = filepath.Abs(self)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: could not resolve my own path: %v\n", err)
		return 1
	}

	// STALE LEFTOVERS ARE SWEPT; FRESH ONES ARE LEFT ALONE.
	//
	// `hdp pair` removes its own line on every exit path it controls, but not on
	// the ones it does not: a SIGKILL, a closed terminal, a machine that lost
	// power. Those leave a `hdp-bootstrap-*` line behind for good, so someone
	// who tries pairing three times over a month ends up with three one-time
	// credentials and nothing on screen to tell them apart.
	//
	// BUT A FRESH ONE MIGHT BELONG TO A RUN THAT IS STILL WAITING, and the first
	// version of this swept unconditionally — deleting every `hdp-bootstrap-*`
	// line on the way in, on the stated grounds that they were all inert. They
	// are not, and that was measurable: start `hdp pair` in one terminal, start
	// it again in another because the first "seemed stuck", and the second run
	// silently kills the first one's code. Scanning the first code then fails
	// authentication, and the app can only report that as "this pairing code has
	// expired" — which is a lie about a code that was valid a second earlier.
	//
	// So age decides. Anything older than the longest a pairing could possibly
	// still be running is swept; anything younger is left, because two live
	// bootstrap lines coexist perfectly well (they carry different tokens, and
	// each run cleans up only its own).
	staleAfter := *window + time.Minute
	if staleAfter < minStaleAfter {
		staleAfter = minStaleAfter
	}
	now := time.Now()

	swept, err := keys.RemoveMatching(func(l string) bool {
		return isStaleBootstrap(l, now, staleAfter)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}
	if swept > 0 {
		fmt.Printf("Removed %d leftover pairing code(s) from an earlier run.\n\n", swept)
	}
	if live := liveBootstrapCount(keys, now, staleAfter); live > 0 {
		fmt.Printf(
			"Note: %d pairing code(s) issued in the last %s are still in %s.\n"+
				"      If you have another `hdp pair` running, its code is still valid.\n\n",
			live, staleAfter.Round(time.Minute), keys.Path)
	}

	// A machine that is already paired gets one keystroke of confirmation.
	// "Pair another phone" is not what someone wants when they meant to retry a
	// failed attempt, and from here the two are indistinguishable. Skipped
	// entirely when stdin is not a terminal, so a script piping into `hdp pair`
	// is not left waiting on a prompt nobody can see.
	if !*force && existingPairedPhones(keys) > 0 && stdinIsTerminal() {
		if !confirm("Pair another phone with this machine?") {
			fmt.Println("Nothing was changed.")
			return 0
		}
	}

	token := fmt.Sprintf("%d", time.Now().UnixNano())
	// The resolved path travels INTO the forced command, so the two halves of
	// pairing cannot disagree about which file to write. See BootstrapLine.
	line := BootstrapLine(pubLine, self, keys.Path, token)

	// The cleanup is registered BEFORE the line is written, and it is
	// idempotent. Every exit path from here — success, timeout, Ctrl-C, a
	// panic — has to remove it, because the one outcome that must never happen
	// is a bootstrap key left in authorized_keys with nobody watching for it.
	installed := false
	cleanup := func() {
		if !installed {
			return
		}
		installed = false
		if _, err := keys.RemoveMatching(func(l string) bool {
			return strings.Contains(l, bootstrapMarker+token)
		}); err != nil {
			fmt.Fprintf(os.Stderr,
				"\nhdp: WARNING — could not remove the temporary key from %s: %v\n"+
					"     Remove the line containing %s%s by hand.\n",
				keys.Path, err, bootstrapMarker, token)
		}
	}
	defer cleanup()

	// AND ON THE SIGNALS, because `defer` does not run for them. Go's default
	// SIGINT handler terminates the process immediately, so Ctrl-C — which is
	// exactly what someone presses when they decide NOT to finish pairing — was
	// the one exit path that skipped the cleanup and left the credential
	// behind. Measured: it did.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		cleanup()
		fmt.Fprintln(os.Stderr, "\nCancelled. The temporary key was removed.")
		os.Exit(130)
	}()

	if err := keys.Add(line); err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}
	installed = true

	p := Pairing{
		Version:     PairingVersion,
		Host:        resolvedHost,
		Port:        *port,
		User:        resolvedUser,
		Key:         privatePEM,
		Fingerprint: fingerprint,
		Name:        *name,
	}
	payload, err := p.Encode()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	switch {
	case *asJSON:
		// A machine-readable form for whoever wants to put this somewhere else
		// — a browser, another machine's screen, a QR printer.
		fmt.Printf(
			`{"pair_url":%q,"fingerprint":%q,"user":%q,"host":%q,"port":%d,"expires_in":%d}`+"\n",
			payload, fingerprint, resolvedUser, resolvedHost, *port, int(window.Seconds()),
		)
	case *noQR:
		fmt.Println(payload)
	default:
		printPairing(os.Stdout, payload, p,
			instructionLines(int(window.Seconds()), candidates))
	}

	fmt.Fprintf(os.Stdout, "\nAuthorized keys file: %s\n", keys.Path)
	fmt.Fprintln(os.Stdout, "Waiting for the phone to install its key…")

	deadline := time.Now().Add(*window)
	installedKey, err := waitForClientKey(keys, deadline)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nhdp: %v\n", err)
		return 1
	}

	// Remove OUR line first, then report. Printing success before the cleanup
	// has happened would mean a failure between the two tells the user pairing
	// worked while the temporary credential is still live.
	cleanup()

	fmt.Fprintf(os.Stdout, "\nPaired. The phone installed:\n  %s\n", installedKey)
	fmt.Fprintln(os.Stdout,
		"\nThe temporary key has been removed from your authorized_keys.")
	return 0
}

// waitForClientKey polls authorized_keys until the phone's own key shows up.
//
// POLLING RATHER THAN BEING TOLD. The forced command runs in a short-lived
// process with no way to signal its parent — sshd started it, not us — so the
// only shared state is the file itself. Polling a file the user owns, at 2 s,
// for at most a few minutes, is the cheapest correct answer available.
func waitForClientKey(keys *AuthorizedKeys, deadline time.Time) (string, error) {
	for {
		lines, err := keys.Lines()
		if err == nil {
			for _, line := range lines {
				if strings.Contains(line, clientMarker) {
					return describeKey(line), nil
				}
			}
		}

		if time.Now().After(deadline) {
			return "", errors.New(
				"timed out waiting for the phone — the pairing code has expired.\n" +
					"     Run `hdp pair` again to start a new one")
		}
		time.Sleep(2 * time.Second)
	}
}

// describeKey gives the user something recognisable to check.
//
// The key TYPE and its fingerprint, not the whole line: the point is that the
// person can tell one phone from another, and a 400-character blob does not do
// that.
func describeKey(line string) string {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return "a key (could not be read back)"
	}
	kind := fields[0]
	if fp, err := fingerprintOfAuthorizedKey(line); err == nil {
		return kind + " " + fp
	}
	return kind
}

// runExchange is the forced command. It runs ON THE HOST, inside sshd's own
// process tree, with the SSH channel as its stdin and stdout.
//
// It appends whatever public key arrives on stdin to authorized_keys. That is
// ALL it does, and there is no argument it accepts that would let it do
// anything else — which is what makes it safe to expose to a key that has been
// written into a QR code.
//
// The reachability argument is the important one: this program is only ever run
// by sshd, and only for a key whose authorized_keys line names it as the forced
// command. A caller who cannot present that key cannot reach it at all.
func runExchange(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	scanner := bufio.NewScanner(stdin)
	// A public key line is well under 8 KiB even for RSA-4096; the default
	// 64 KiB scanner limit is already generous, and raising it would only make
	// a malformed paste more expensive to reject.
	if !scanner.Scan() {
		fmt.Fprintln(stderr, "hdp: no public key arrived on stdin")
		return 1
	}
	line := strings.TrimSpace(scanner.Text())

	if err := validatePublicKeyLine(line); err != nil {
		fmt.Fprintf(stderr, "hdp: %v\n", err)
		return 1
	}

	// The path comes from the forced command's own argument when there is one,
	// and is only resolved locally as a fallback for a hand-run invocation.
	// Resolving it here would be the second independent answer to a question
	// that must have exactly one.
	var keys *AuthorizedKeys
	if len(args) > 0 && args[0] != "" {
		keys = &AuthorizedKeys{Path: args[0]}
	} else {
		var err error
		keys, err = ResolveAuthorizedKeys()
		if err != nil {
			fmt.Fprintf(stderr, "hdp: %v\n", err)
			return 1
		}
	}

	// Idempotent: pairing twice from the same phone must not append the same
	// key twice, which would leave the user with two identical lines and no way
	// to tell which `hdp unpair` removed.
	existing, err := keys.Lines()
	if err != nil {
		fmt.Fprintf(stderr, "hdp: %v\n", err)
		return 1
	}
	for _, have := range existing {
		if sameKeyMaterial(have, line) {
			fmt.Fprintln(stdout, exchangeOK)
			return 0
		}
	}

	if err := keys.Add(line); err != nil {
		fmt.Fprintf(stderr, "hdp: %v\n", err)
		return 1
	}

	// The marker the waiting `hdp pair` is polling for. It is the APP that adds
	// `hdp-pocket` to the comment, so nothing here has to invent one; if the
	// app forgets, pairing times out rather than succeeding silently.
	fmt.Fprintln(stdout, exchangeOK)
	return 0
}

// exchangeOK is what the phone looks for to know the key was installed.
const exchangeOK = "HDP-EXCHANGE-OK"

// validatePublicKeyLine rejects anything that is not a public key.
//
// THE SECURITY-CRITICAL FUNCTION IN THIS FILE, and it is an allow-list rather
// than an escape. `authorized_keys` lines may contain options (`command=`,
// `environment=`, `permitopen=`), and a line crafted as
// `command="curl …| sh" ssh-ed25519 AAAA…` would be executed by sshd on the
// next login. So: a known key type, followed by base64 that decodes as an SSH
// public key blob, and nothing in front of it.
func validatePublicKeyLine(line string) error {
	if line == "" {
		return errors.New("the phone sent an empty key")
	}
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return errors.New("the phone sent something that is not a public key")
	}
	if !strings.HasPrefix(fields[0], "ssh-") && !strings.HasPrefix(fields[0], "ecdsa-") {
		return fmt.Errorf(
			"refusing to install a key of type %q — only plain ssh-* and ecdsa-* "+
				"keys are accepted, because anything before the key type would be "+
				"read by sshd as options", fields[0])
	}
	if len(line) > 8192 {
		return errors.New("that key line is implausibly long")
	}
	// The comment is free-form, but a NEWLINE in it would smuggle a second
	// authorized_keys entry past this check and past the single-line record
	// framing the caller used.
	if strings.ContainsAny(line, "\r\n\x00") {
		return errors.New("that key line contains a control character")
	}
	return nil
}

// sameKeyMaterial compares two authorized_keys lines by their key blob.
//
// By BLOB, not by whole line: the comment differs between the phone's first
// pairing and a later one, and comparing whole lines would append a duplicate
// every time the user re-paired the same device.
func sameKeyMaterial(a, b string) bool {
	af, bf := strings.Fields(a), strings.Fields(b)
	if len(af) < 2 || len(bf) < 2 {
		return false
	}
	return af[0] == bf[0] && af[1] == bf[1]
}

// / How many phones this machine has paired.
func existingPairedPhones(keys *AuthorizedKeys) int {
	lines, err := keys.Lines()
	if err != nil {
		return 0
	}
	n := 0
	for _, line := range lines {
		if strings.Contains(line, clientMarker) {
			n++
		}
	}
	return n
}

// / Asks a yes/no question on the terminal.
// /
// / Only ever reached when stdin is a terminal, because a script that pipes
// / something into `hdp pair` would otherwise have its input eaten by a prompt
// / nobody can see.
func confirm(question string) bool {
	fmt.Printf("%s [y/N] ", question)
	reader := bufio.NewReader(os.Stdin)
	answer, err := reader.ReadString('\n')
	if err != nil {
		return false
	}
	answer = strings.ToLower(strings.TrimSpace(answer))
	return answer == "y" || answer == "yes"
}

// / Whether stdin is a terminal rather than a pipe or a file.
// /
// / The check itself is the whole answer, so there is no default to get wrong.
func stdinIsTerminal() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// / Whether a `hdp-bootstrap-*` line is old enough to be swept.
// /
// / Age is read out of the line itself: the token is the timestamp of the run
// / that wrote it, which is what makes this answerable at all — a marker with no
// / time in it could only be judged by guessing.
// /
// / A line whose token does not parse is swept. It was written by a build with a
// / different token format, so it cannot be a run that is waiting right now.
func isStaleBootstrap(line string, now time.Time, staleAfter time.Duration) bool {
	at := strings.LastIndex(line, bootstrapMarker)
	if at < 0 {
		return false
	}
	nanos, err := strconv.ParseInt(strings.TrimSpace(line[at+len(bootstrapMarker):]), 10, 64)
	if err != nil {
		return true
	}
	return now.Sub(time.Unix(0, nanos)) > staleAfter
}

// / How many bootstrap lines are recent enough to belong to a live run.
func liveBootstrapCount(keys *AuthorizedKeys, now time.Time, staleAfter time.Duration) int {
	lines, err := keys.Lines()
	if err != nil {
		return 0
	}
	n := 0
	for _, line := range lines {
		if strings.Contains(line, bootstrapMarker) && !isStaleBootstrap(line, now, staleAfter) {
			n++
		}
	}
	return n
}
