// Package main — `hdp list` and `hdp unpair`.
//
// Both work off the comments the app writes, which is the whole reason those
// comments exist: a pairing that cannot be undone from the tool that made it is
// a key the user has to go and find by hand, and that is the step at which they
// give up and leave it in place.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

func runList(args []string) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	keys, err := ResolveAuthorizedKeys()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}
	lines, err := keys.Lines()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	fmt.Printf("Authorized keys file: %s\n\n", keys.Path)

	paired := 0
	for _, line := range lines {
		if !strings.Contains(line, clientMarker) {
			continue
		}
		paired++
		name := commentOf(line)
		if name == "" {
			name = "(no label)"
		}
		fmt.Printf("  %-28s %s\n", name, describeKey(line))
	}

	if paired == 0 {
		fmt.Println("  No phones are paired with this machine.")
		fmt.Println("  Run `hdp pair` to add one.")
		return 0
	}
	fmt.Printf("\n%d paired. Remove one with: hdp unpair <the part after hdp-pocket->\n", paired)
	return 0
}

func runUnpair(args []string) int {
	fs := flag.NewFlagSet("unpair", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: hdp unpair <token>")
		fmt.Fprintln(os.Stderr, "       the token is what `hdp list` shows after `hdp-pocket-`")
		return 2
	}
	want := fs.Arg(0)

	keys, err := ResolveAuthorizedKeys()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	removed, err := keys.RemoveMatching(func(line string) bool {
		if !strings.Contains(line, clientMarker) {
			return false
		}
		// An empty token matches every paired phone — refused rather than
		// treated as a wildcard, because the command that removes all of them
		// by accident is not a command anyone types on purpose.
		return want != "" && strings.Contains(line, clientMarker+"-"+want)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "hdp: %v\n", err)
		return 1
	}

	if removed == 0 {
		fmt.Fprintf(os.Stderr,
			"hdp: no paired phone matches %q — run `hdp list` to see them\n", want)
		return 1
	}

	fmt.Printf("Removed %d key(s). That phone can no longer connect.\n", removed)
	return 0
}

// commentOf returns the free-form trailing comment of an authorized_keys line,
// or "" when there is none.
func commentOf(line string) string {
	fields := strings.Fields(line)
	if len(fields) < 3 {
		return ""
	}
	return strings.Join(fields[2:], " ")
}
