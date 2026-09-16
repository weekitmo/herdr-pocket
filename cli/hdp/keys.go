// Package main — key generation and the host key fingerprint.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"

	"golang.org/x/crypto/ssh"
)

// NewBootstrapKey makes the one-time key that goes into the pairing string.
//
// ed25519 and nothing else. It is what modern sshd assumes, and its private half
// is 32 bytes — which is the whole reason it is the one key type that works
// here at all. An RSA-4096 bootstrap key would put a 3 KB payload in a QR code
// nobody can scan.
//
// ## It returns the SEED, not a PEM
//
// The obvious implementation returns `ssh.MarshalPrivateKey`'s PEM, and the
// first version did. Measured: that is ~400 characters of base64, which through
// the payload's own base64 becomes a **version-19 code, 93 modules square** —
// 93 terminal COLUMNS, which does not fit a default 80-column terminal at all,
// and which a phone camera has to resolve 93 modules across. It scanned badly
// because it was genuinely too big.
//
// The seed is 44 characters and the app rebuilds the PEM from it, because
// `openssh-key-v1` is a container around exactly this: 32 bytes of seed, the
// public key derived from it, and a comment. Nothing is lost — the seed IS the
// key — and the code comes down to a size a camera can actually read.
//
// NO PASSPHRASE. A passphrase on a key delivered by QR is a passphrase the user
// has to copy out of the same QR, which is the friction this feature exists to
// remove; the protection is the forced command and the deletion, not a secret
// stored beside the key.
func NewBootstrapKey() (seedBase64 string, authorizedKey string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", fmt.Errorf("could not generate a key: %w", err)
	}

	// `ed25519.PrivateKey` is the seed followed by the public key, so `Seed()`
	// is the 32 bytes the app needs and nothing else.
	seedBase64 = base64.RawStdEncoding.EncodeToString(priv.Seed())

	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		return "", "", fmt.Errorf("could not encode the public key: %w", err)
	}
	// No comment here: BootstrapLine appends its own marker, and a second
	// comment inside the key blob would end up as a stray field between the
	// key and the options sshd parses.
	authorizedKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub)))
	return seedBase64, authorizedKey, nil
}

// CurrentUser is the login name the phone should connect as.
func CurrentUser() (string, error) {
	if override := os.Getenv("HDP_USER"); override != "" {
		return override, nil
	}
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username, nil
	}
	if name := os.Getenv("USER"); name != "" {
		return name, nil
	}
	return "", errors.New("could not work out your username; pass --user")
}

// CandidateHosts lists the addresses this machine might be reachable at.
//
// ORDERED BY HOW LIKELY THEY ARE TO BE THE RIGHT ANSWER, because the flag that
// overrides this exists: a laptop on a tailnet has a better name than any LAN
// address, and only the human knows that. The default is the first entry, and
// the rest are printed so the override is a copy-paste rather than a guess.
func CandidateHosts() []string {
	var out []string
	seen := map[string]bool{}

	add := func(addr string) {
		if addr == "" || seen[addr] {
			return
		}
		seen[addr] = true
		out = append(out, addr)
	}

	if name, err := os.Hostname(); err == nil {
		// A bare hostname only helps if it resolves from the phone, which on a
		// home network with mDNS it often does. Listed first because when it
		// works it keeps working when the address changes.
		if !strings.Contains(name, ".") {
			add(name + ".local")
		}
		add(name)
	}

	ifaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				ipnet, ok := a.(*net.IPNet)
				if !ok {
					continue
				}
				ip4 := ipnet.IP.To4()
				if ip4 == nil {
					continue
				}
				// 169.254/16 is the "DHCP failed" address: it is up, it is
				// routable, and nothing can reach it.
				if ip4[0] == 169 && ip4[1] == 254 {
					continue
				}
				add(ip4.String())
			}
		}
	}
	return out
}

// HostKeyFingerprint returns the fingerprint of the key this machine's sshd
// will actually present, in the `SHA256:…` form `ssh-keygen -lf` prints.
//
// The value that turns the QR into an authenticated channel: with it, the app
// pins the server on first connection instead of asking the user to compare a
// fingerprint by eye — a step users skip, and which therefore protects nobody.
//
// ## Ask the server first, read the files second
//
// The obvious implementation reads `/etc/ssh/ssh_host_ed25519_key.pub`, and it
// is WRONG in a way that only shows up on somebody else's machine. Those files
// are the DEFAULTS; an `sshd_config` with its own `HostKey` line — which is what
// a second sshd on a spare port looks like, and what a machine that rotated its
// keys looks like — serves something else entirely. The app then pins the
// fingerprint `hdp` guessed, sees a different key on the wire, and reports a
// host key MISMATCH. That is the loudest alarm this app has, raised at the
// person who did nothing wrong, on a machine nobody attacked.
//
// Measured, in the interop test that pairs the real hdp with the Dart client:
// the connection was dropped mid-key-exchange because the pinned fingerprint
// came from `/etc/ssh` and the throwaway sshd was using its own key.
//
// So the order is: ask the running server, then read the files as a fallback
// for a machine whose sshd is not up yet.
func HostKeyFingerprint(host string, port int) (string, error) {
	// ssh-keyscan performs a real handshake, so what it reports is by
	// construction what a client will see. Absent from minimal images, hence
	// the fallback rather than a hard requirement.
	if _, err := exec.LookPath("ssh-keyscan"); err == nil {
		out, err := exec.Command(
			"ssh-keyscan", "-t", "ed25519", "-p", strconv.Itoa(port), host,
		).Output()
		if err == nil {
			if fp, err := fingerprintOfAuthorizedKey(string(out)); err == nil {
				return fp, nil
			}
		}
	}

	var tried []string
	// The public key files are world-readable on every distribution; the
	// private ones are not, and are not needed.
	for _, path := range []string{
		"/etc/ssh/ssh_host_ed25519_key.pub",
		"/etc/ssh/ssh_host_ecdsa_key.pub",
		"/etc/ssh/ssh_host_rsa_key.pub",
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			tried = append(tried, path)
			continue
		}
		fp, err := fingerprintOfAuthorizedKey(string(data))
		if err != nil {
			tried = append(tried, path)
			continue
		}
		return fp, nil
	}

	return "", fmt.Errorf(
		"could not work out this machine's host key (tried ssh-keyscan, then %s).\n"+
			"     No SSH client will connect without it: the pairing string carries it so\n"+
			"     the app can pin the server rather than ask you to compare a fingerprint\n"+
			"     by hand",
		strings.Join(tried, ", "))
}

// fingerprintOfAuthorizedKey computes an OpenSSH SHA256 fingerprint from one or
// more public key lines.
//
// The digest is over the BASE64-DECODED BLOB, not over the text of the line.
// Hashing the text produces a string of exactly the right shape that matches
// nothing, and the failure it causes — "the app says the host key changed on a
// machine that was never touched" — sends the user looking at the wrong thing
// entirely. OpenSSH's own format is `SHA256:` + base64url of the digest, with
// the padding stripped.
func fingerprintOfAuthorizedKey(text string) (string, error) {
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		// ANCHORED ON THE KEY TYPE, not on a fixed column index — because the
		// two sources disagree about which column that is:
		//
		//     /etc/ssh/ssh_host_ed25519_key.pub   ssh-ed25519 AAAAC3… comment
		//     ssh-keyscan output                  127.0.0.1 ssh-ed25519 AAAAC3…
		//
		// Taking `fields[1]` as the blob works for the first and silently
		// decodes the literal string "ssh-ed25519" for the second, which fails
		// base64 and makes the fallback dead code that looks alive.
		for i, field := range fields {
			if i+1 >= len(fields) {
				break
			}
			if !strings.HasPrefix(field, "ssh-") && !strings.HasPrefix(field, "ecdsa-") {
				continue
			}
			blob, err := base64.StdEncoding.DecodeString(fields[i+1])
			if err != nil {
				continue
			}
			sum := sha256.Sum256(blob)
			return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:]), nil
		}
	}
	return "", errors.New("no public key in that file")
}
