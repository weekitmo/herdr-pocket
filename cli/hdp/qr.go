// Package main — the terminal side of `hdp pair`.
package main

import (
	"fmt"
	"io"
	"strings"

	qrcode "github.com/mdp/qrterminal/v3"
)

// printPairing renders the pairing string as a QR code and prints the same
// string underneath it.
//
// THE TWO HALVES ARE THE SAME DATA, and that is the design rather than a
// convenience. The app runs one parser over whatever it gets, so a scan and a
// paste cannot disagree — and when a scan fails (a terminal at the wrong size,
// a reversed light-on-dark colour scheme, a camera that will not focus on a
// screen) the string below it is the answer, already on screen, needing no
// second command.
func printPairing(w io.Writer, payload string, p Pairing, extras []string) {
	// LOW RECOVERY, because this code is read off a screen at close range by a
	// camera the user is holding still. The failure mode of a high correction
	// level here is a denser code that is HARDER to scan, which is the opposite
	// of what it is for.
	//
	// Half-block characters halve the height: a version-15 code is 77 modules
	// square, which is 77 columns and 39 rows this way — inside a default
	// terminal, where drawing it as two characters per module would be 77 rows
	// and would scroll the instructions off the screen.
	qrcode.GenerateWithConfig(payload, qrcode.Config{
		Level: qrcode.L,
		// HALF BLOCKS, and this one flag is worth as much as the payload diet.
		// Without it `qrterminal` writes one character per module and one LINE
		// per module — a square of 93 columns by 93 rows for the old payload.
		// With it each line carries two rows of modules using `▀`/`▄`/`█`, so
		// the code is half as tall and fits a terminal that is 93 columns wide
		// but only 50 lines high, which is most of them.
		HalfBlocks: true,
		Writer:     w,
		// Level L is the LOWEST correction, and that is the point: more
		// redundancy means more modules for the same data, and this code is
		// read off a screen at close range by a hand that is holding still. A
		// denser code is a harder one to scan, which is the opposite of what
		// the redundancy is for.
		QuietZone: 2,
	})

	fmt.Fprintln(w)
	fmt.Fprintln(w, "  "+p.Summary())
	fmt.Fprintln(w)
	fmt.Fprintln(w, "  Scan the code above with Herdr Pocket (recommended).")
	fmt.Fprintln(w, "  If you cannot scan it, copy the whole string below and paste it")
	fmt.Fprintln(w, "  into the app's pairing screen instead — it is the same data.")
	fmt.Fprintln(w)

	// Wrapped, because a 700-character line in a terminal wraps wherever it
	// likes and a mid-string break is what makes a copy-paste go wrong.
	for _, line := range wrap(payload, 72) {
		fmt.Fprintln(w, "  "+line)
	}

	for _, extra := range extras {
		fmt.Fprintln(w)
		fmt.Fprintln(w, "  "+extra)
	}
}

// wrap breaks [s] into chunks of at most [width] characters.
//
// Chunked rather than word-wrapped: the string has no words, and the only thing
// that matters is that no line is broken by the terminal itself.
func wrap(s string, width int) []string {
	if width <= 0 || len(s) <= width {
		return []string{s}
	}
	var out []string
	for len(s) > width {
		out = append(out, s[:width])
		s = s[width:]
	}
	if len(s) > 0 {
		out = append(out, s)
	}
	return out
}

// instructionLines returns the transient guidance printed under the code.
//
// Separate from printPairing so the wording can be tested without capturing a
// rendered QR code, which is a wall of block characters no assertion should be
// written against.
func instructionLines(timeoutSeconds int, others []string) []string {
	lines := []string{
		fmt.Sprintf("Waiting for the phone… (this code stops working in %ds)",
			timeoutSeconds),
	}
	if len(others) > 1 {
		// The override, offered rather than explained: the common case is that
		// the first address is right, and the case where it is not is a machine
		// with several networks.
		lines = append(lines, "If the phone cannot reach that address, re-run with one of: "+
			strings.Join(others[1:], ", "))
	}
	return lines
}
