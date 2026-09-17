#!/bin/sh
#
# Prints one version's entry out of CHANGELOG.md.
#
# WHAT IT IS FOR. The release body should be the entry a human wrote, not a list
# of commit subjects — and the two must not be able to drift. So the workflow
# does not carry its own prose: it reads the same section a person reads before
# tagging, which is why this is a script rather than an `awk` incantation that
# lives only inside a YAML file.
#
# AND A RELEASE WITHOUT NOTES FAILS HERE, on purpose. A tag pushed with no entry
# publishes a release whose body says nothing, and by the time anyone notices it
# is published. `hdp-release.yml` says the same thing in one line: a generated
# changelog that lists commit subjects is worse than the tag itself.
#
# Usage:
#   sh tool/release_notes.sh 0.2.1           # the section on stdout
#   sh tool/release_notes.sh --check 0.2.1   # nothing on stdout; exit code only
#
# The version may be given with or without a leading `v`, because a tag is one
# and a pubspec version is not.
set -eu

usage() {
  echo "usage: sh tool/release_notes.sh [--check] <version>" >&2
  exit 2
}

check_only=0
if [ "${1:-}" = "--check" ]; then
  check_only=1
  shift
fi

[ $# -eq 1 ] || usage

version=${1#v}
case "$version" in
  '' | */*) usage ;;
esac

cd "$(dirname "$0")/.."

[ -f CHANGELOG.md ] || {
  echo "tool/release_notes.sh: CHANGELOG.md is missing" >&2
  exit 1
}

# The section is everything between `## [<version>]` and the next section —
# which is either the next `## [` heading or the `<a id>` anchor sitting just
# above it, so the anchor never leaks into a release body.
# Matching on the bracketed version rather than on the heading text keeps the
# heading free: `## [0.2.1]` and `## [0.2.1] - 2026-09-17` both work, and so does
# anything appended to the title after the bracket.
body=$(
  awk -v want="$version" '
    index($0, "## [" want "]") == 1 { capture = 1; next }
    capture && (index($0, "## [") == 1 || index($0, "<a id=") == 1) { exit }
    # The `---` between two entries is for the file, not for a release body.
    capture && $0 ~ /^---[[:space:]]*$/ { next }
    capture { print }
  ' CHANGELOG.md
)

if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
  echo "tool/release_notes.sh: CHANGELOG.md has no '## [$version]' section." >&2
  echo "Write the entry before tagging — the release body is taken from it." >&2
  exit 1
fi

[ "$check_only" -eq 1 ] || printf '%s\n' "$body"
