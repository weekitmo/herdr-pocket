// Package pairing defines the string that carries everything a phone needs to
// pair, in the one encoding both delivery paths share.
//
// THE QR CODE AND THE PASTED STRING ARE THE SAME BYTES. The terminal renders
// the payload as a QR and prints the identical base64url text underneath it; the
// app accepts either and runs one parser over both. Two formats would mean two
// sets of edge cases, and "the scan works but the paste does not" is the worst
// kind of bug to find, because the person who hits it has already proved the
// feature can work.
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// PairingVersion is the only payload version this build understands.
//
// Carried in the payload from the first release so a future format change can
// be reported as "this pairing string came from a newer hdp; update the app"
// rather than as a parse failure. A version field added later never gets this
// right, because the payloads that need it are the ones already in the wild.
const PairingVersion = 1

// Pairing is everything the app needs from a `hdp pair` invocation.
type Pairing struct {
	Version int `json:"v"`

	// Host is what the phone will dial — a LAN address, a hostname, or a
	// Tailscale name. Whatever `hdp` resolved locally is what goes in, because
	// only the host itself knows which of its addresses is reachable.
	Host string `json:"h"`

	Port int    `json:"p"`
	User string `json:"u"`

	// Key is the one-time bootstrap key's 32-byte SEED, base64 (44 characters).
	//
	// Not a PEM, and the difference is the difference between a scannable code
	// and an unscannable one — see [NewBootstrapKey]. The app rebuilds the
	// `openssh-key-v1` container from this, which is all that container holds.
	//
	// The field that makes this payload a SECRET. It is useless on its own —
	// the matching line in authorized_keys carries a forced command, so the key
	// can run exactly one thing, and that line is deleted the moment pairing
	// finishes or the window closes. But it is still a credential, so nothing
	// here may be logged and `String()` deliberately omits it.
	Key string `json:"k"`

	// Fingerprint pins the server's host key, so the first connection needs no
	// trust-on-first-use prompt. THIS is what makes the QR an out-of-band
	// channel rather than a convenience: the value that would have to be
	// verified by hand arrives over a channel a network attacker cannot touch.
	Fingerprint string `json:"f"`

	// Name is a label for the machines list, e.g. "Mac mini". Optional.
	Name string `json:"n,omitempty"`
}

// String redacts the key.
//
// A struct printed with %v in an error path or a debug log would otherwise put
// a private key into a terminal that someone is screen-sharing. The one field
// worth printing is the host; everything else is either boring or secret.
func (p Pairing) String() string {
	return fmt.Sprintf("Pairing(%s@%s:%d v%d)", p.User, p.Host, p.Port, p.Version)
}

// Validate checks the fields the app would otherwise have to defend against.
func (p Pairing) Validate() error {
	if p.Version != PairingVersion {
		return fmt.Errorf(
			"pairing string is version %d, this build speaks %d — update hdp or the app",
			p.Version, PairingVersion)
	}
	if p.Host == "" {
		return errors.New("pairing string has no host")
	}
	if p.Port <= 0 || p.Port > 65535 {
		return fmt.Errorf("pairing string has an impossible port: %d", p.Port)
	}
	if p.User == "" {
		return errors.New("pairing string has no user")
	}
	if p.Key == "" {
		return errors.New("pairing string has no key")
	}
	if !strings.HasPrefix(p.Fingerprint, "SHA256:") {
		return errors.New("pairing string has no SHA256 host key fingerprint")
	}
	return nil
}

// Encode renders the payload as the string that is both printed and drawn.
//
// base64url WITHOUT padding, because the string is meant to survive a human
// round trip: pasted into a chat, an email, a password manager, a QR code
// reader. `whip` uses Base45, which packs tighter into the alphanumeric QR mode
// — and would have cost the paste path, which is the half of this feature that
// works when the phone is nowhere near the host.
func (p Pairing) Encode() (string, error) {
	if err := p.Validate(); err != nil {
		return "", err
	}
	// Field order in the JSON is the struct's, and `v` is declared first on
	// purpose: a decoder only has to read one byte to know whether to continue.
	raw, err := json.Marshal(p)
	if err != nil {
		return "", fmt.Errorf("could not encode the pairing string: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

// Decode parses a pairing string.
//
// Whitespace and newlines are stripped first. The string is meant to be pasted,
// and a paste out of a wrapped terminal or a chat client arrives with line
// breaks in it — refusing that would be refusing the exact use the paste path
// exists for.
func Decode(encoded string) (Pairing, error) {
	cleaned := strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\n', '\r', '\t':
			return -1
		}
		return r
	}, encoded)

	if cleaned == "" {
		return Pairing{}, errors.New("no pairing string was given")
	}

	raw, err := base64.RawURLEncoding.DecodeString(cleaned)
	if err != nil {
		// Tolerate padded input: some chat clients and most JWT libraries add
		// the `=` back. Trying the padded alphabet costs one decode and turns
		// a mystifying "invalid character" into a working paste.
		raw, err = base64.URLEncoding.DecodeString(cleaned)
		if err != nil {
			return Pairing{}, errors.New(
				"this does not look like a pairing string — it should be a long " +
					"string of letters, digits, `-` and `_`")
		}
	}

	var p Pairing
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	// Reject unknown fields rather than ignoring them: a payload with fields
	// this build does not know about came from a newer hdp, and silently
	// dropping them is how a pairing succeeds with half the information.
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&p); err != nil {
		return Pairing{}, errors.New(
			"this pairing string could not be read — it may come from a newer hdp")
	}
	if err := p.Validate(); err != nil {
		return Pairing{}, err
	}
	return p, nil
}

// Summary is the one-line description shown under the QR.
//
// Everything the user is meant to check before scanning, and nothing that would
// make the line unreadable. The fingerprint is deliberately not here: it is 47
// characters of base64, and putting it on a terminal line pushes the host and
// the user off the screen. It travels in the payload where it is actually used.
func (p Pairing) Summary() string {
	who := fmt.Sprintf("%s@%s:%d", p.User, p.Host, p.Port)
	if p.Name != "" {
		who = fmt.Sprintf("%s (%s)", who, p.Name)
	}
	return who
}
