#!/bin/sh
# hdp installer — https://github.com/weekitmo/herdr-pocket
#
#   curl -sSL https://raw.githubusercontent.com/weekitmo/herdr-pocket/main/cli/hdp/install.sh | sh
#
# The repository is written down in exactly two places — the header above and
# HDP_REPO below — and `HDP_REPO` is overridable so that install_test.sh can run
# this script against a local server instead of GitHub.
#
# ---------------------------------------------------------------------------
# Writing a script that is meant to be PIPED INTO A SHELL has three rules, and
# breaking any of them produces a failure that looks like something else.
#
#  1. NEVER READ FROM STDIN. `curl … | sh` means stdin IS this script. A single
#     `read` — for a confirmation, a choice, anything — swallows the rest of the
#     file and the install stops halfway with no error, because the shell simply
#     reaches EOF and exits 0. Commands that read stdin without saying so
#     (`ssh` without -n, `cat` with no arguments, `git` when it prompts) do the
#     same thing. So: no prompts, and every command that could prompt gets
#     `</dev/null`.
#
#  2. POSIX sh, not bash. It is executed by whatever `sh` is: dash on Debian,
#     busybox ash in containers, bash-as-sh on macOS. `[[ ]]`, arrays, `local`
#     and `echo -e` are all things that work on the machine it was tested on.
#
#  3. `set -eu`, and every expansion quoted. A half-finished install that
#     reports success is worse than one that stops.
#
# ---------------------------------------------------------------------------
# What the checksum check is and is not for.
#
# The tarball and the checksums come from the same origin over the same TLS
# connection, so this does NOT defend against a compromised repository or a
# mis-issued certificate — nothing delivered this way can. What it does defend
# against is the thing that actually happens: a truncated or corrupted
# download, a proxy that rewrote the body, a cached asset that is one release
# old. That is worth a few lines, and it is worth being honest about.
#
# There is deliberately no flag to skip it. A verification step with a bypass
# is a verification step that gets bypassed.
# ---------------------------------------------------------------------------

set -eu

HDP_REPO="${HDP_REPO:-weekitmo/herdr-pocket}"
HDP_VERSION="${HDP_VERSION:-}"          # empty = latest release
HDP_INSTALL_DIR="${HDP_INSTALL_DIR:-}"  # empty = pick a sensible one

# Where the release assets live. Overridable for a mirror (an air-gapped or
# region-blocked network is a real reason to run one) and, usefully, for the
# test that actually executes this script against a local HTTP server instead
# of only checking that it parses — see `install_test.sh`.
HDP_RELEASES_URL="${HDP_RELEASES_URL:-https://github.com/${HDP_REPO}/releases}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'hdp-install: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform ---

detect_os() {
    case "$(uname -s)" in
        Darwin) echo darwin ;;
        Linux)  echo linux ;;
        *)
            fail "unsupported system: $(uname -s).
       hdp ships binaries for macOS and Linux. On Windows, use WSL.
       Build from source: go install github.com/${HDP_REPO}/cli/hdp@latest"
            ;;
    esac
}

detect_arch() {
    # `uname -m` and Go's GOARCH disagree on exactly two shapes, and both are
    # the ones people run: arm64 vs aarch64, and x86_64 vs amd64.
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64)  echo amd64 ;;
        armv7l|armv6l) echo arm ;;

        *)
            fail "unsupported architecture: $(uname -m).
       Prebuilt binaries exist for arm64 and x86_64.
       Build from source: go install github.com/${HDP_REPO}/cli/hdp@latest"
            ;;
    esac
}

# ---------------------------------------------------------------- download ---

# A single downloader, resolved once. `curl` is present on macOS and on every
# Linux that matters; `wget` is the fallback for the minimal images that ship
# without it.
DOWNLOADER=''
pick_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER=curl
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER=wget
    else
        fail "neither curl nor wget is available, so nothing can be downloaded.
       Install one of them, or build from source:
         go install github.com/${HDP_REPO}/cli/hdp@latest"
    fi
}

# fetch URL DEST  — or fetch URL with no DEST to write to stdout.
fetch() {
    if [ "$DOWNLOADER" = curl ]; then
        # -f so an HTTP error is a failure and not an HTML error page written
        # to the destination as if it were a binary.
        # -L because release assets redirect to a CDN.
        curl -fsSL "$1" > "${2:-/dev/stdout}"
    else
        wget -q -O "${2:--}" "$1"
    fi
}

# Resolve the tag of the latest release.
#
# By following the /releases/latest REDIRECT rather than calling the API: the
# API is rate limited per IP (60/hour, and shared behind a NAT or CI runner),
# while the redirect is a plain page load with no limit. The API is the
# fallback for the day the redirect changes shape.
resolve_version() {
    if [ -n "$HDP_VERSION" ]; then
        echo "$HDP_VERSION"
        return
    fi

    if [ "$DOWNLOADER" = curl ]; then
        effective=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "${HDP_RELEASES_URL}/latest" 2>/dev/null || true)
        tag=${effective##*/}
        case "$tag" in
            v[0-9]*) echo "$tag"; return ;;
        esac
    fi

    body=$(fetch "https://api.github.com/repos/${HDP_REPO}/releases/latest" 2>/dev/null || true)
    tag=$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    case "$tag" in
        v[0-9]*) echo "$tag" ;;
        *)
            fail "could not work out the latest version of ${HDP_REPO}.
       Set it explicitly:  HDP_VERSION=v0.1.0 sh install.sh
       If no release has been published yet, build from source:
         go install github.com/${HDP_REPO}/cli/hdp@latest"
            ;;
    esac
}

# ---------------------------------------------------------------- verifying ---

sha256_of() {
    # `shasum` on macOS, `sha256sum` on Linux, and macOS also has shasum for
    # everything. One of the three is always present.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        fail "no way to compute a SHA-256 here (need sha256sum, shasum or openssl)."
    fi
}

verify() {
    file="$1"
    checksums="$2"
    expected=$(awk -v name="$(basename "$file")" '$2 == name {print $1; exit}' "$checksums")
    [ -n "$expected" ] || fail "the release has no checksum for $(basename "$file").
       Refusing to install a binary that cannot be verified."

    actual=$(sha256_of "$file")
    [ "$expected" = "$actual" ] || fail "checksum mismatch for $(basename "$file").
       expected $expected
       got      $actual
       The download was corrupted or tampered with. Nothing was installed."
    say "  checksum ok  ${actual%????????????????????????????????????????????????}"
}

# ----------------------------------------------------------------- install ---

# Where to put it.
#
# ~/.local/bin FIRST rather than /usr/local/bin, because the alternative is
# either sudo (a script piped from the internet asking for root is a habit worth
# not encouraging) or a permission failure at the last step.
pick_install_dir() {
    if [ -n "$HDP_INSTALL_DIR" ]; then
        echo "$HDP_INSTALL_DIR"
        return
    fi
    if [ -w /usr/local/bin ] 2>/dev/null; then
        echo /usr/local/bin
    else
        echo "${HOME}/.local/bin"
    fi
}

# Tell the user how to make `hdp` runnable, if it is not already.
#
# Worth being specific about: the URL form of this installer is usually run on a
# fresh machine, where ~/.local/bin exists and is not on PATH, and "command not
# found" after a successful install reads as a failed install.
report_path() {
    dir="$1"
    case ":${PATH}:" in
        *":${dir}:"*) return ;;
    esac

    say ""
    say "  ${dir} is not on your PATH yet. Add it:"
    case "$(basename "${SHELL:-sh}")" in
        zsh)  say "    echo 'export PATH=\"${dir}:\$PATH\"' >> ~/.zshrc  &&  exec zsh" ;;
        bash) say "    echo 'export PATH=\"${dir}:\$PATH\"' >> ~/.bashrc &&  exec bash" ;;
        fish) say "    fish_add_path ${dir}" ;;
        *)    say "    export PATH=\"${dir}:\$PATH\"   # add this to your shell's rc file" ;;
    esac
}

main() {
    os=$(detect_os)
    arch=$(detect_arch)
    pick_downloader
    version=$(resolve_version)

    # The leading `v` is in the tag but not in the asset name, which is the
    # convention every Go release tool uses.
    bare=${version#v}
    asset="hdp_${bare}_${os}_${arch}.tar.gz"
    base="${HDP_RELEASES_URL}/download/${version}"

    say "hdp ${version}  (${os}/${arch})"
    say ""

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hdp-install.XXXXXX")
    # Cleanup on every exit path, including the ones that call fail() and the
    # ones interrupted with Ctrl-C — a leftover half-downloaded binary in a temp
    # directory is exactly the kind of thing that gets found later and trusted.
    trap 'rm -rf "$tmp"' EXIT INT TERM HUP

    say "  downloading ${asset}"
    fetch "${base}/${asset}" "${tmp}/${asset}" \
        || fail "could not download ${base}/${asset}
       Check that ${version} has a build for ${os}/${arch}."

    fetch "${base}/checksums.txt" "${tmp}/checksums.txt" \
        || fail "could not download the checksums for ${version}.
       Refusing to install an unverifiable binary."
    verify "${tmp}/${asset}" "${tmp}/checksums.txt"

    tar -xzf "${tmp}/${asset}" -C "$tmp" \
        || fail "the release archive could not be unpacked."
    [ -f "${tmp}/hdp" ] || fail "the archive did not contain an hdp binary."

    dir=$(pick_install_dir)
    mkdir -p "$dir" || fail "could not create ${dir}."
    [ -w "$dir" ] || fail "${dir} is not writable.
       Set HDP_INSTALL_DIR to somewhere you own, or re-run with sudo."

    # Installed beside the target and renamed, so a failure cannot leave a
    # truncated `hdp` in place of a working one — and so the rename is atomic
    # for any `hdp` process that is running right now.
    install -m 0755 "${tmp}/hdp" "${dir}/hdp.new" 2>/dev/null \
        || { cp "${tmp}/hdp" "${dir}/hdp.new" && chmod 0755 "${dir}/hdp.new"; }
    mv -f "${dir}/hdp.new" "${dir}/hdp"

    say "  installed    ${dir}/hdp"
    report_path "$dir"

    say ""
    say "Next:"
    say "  hdp pair        # shows a QR code the phone can scan"

    # Worth saying out loud, because it is the one thing about hdp that a
    # reinstall can break: a paired phone's authorized_keys line contains the
    # ABSOLUTE path of this binary as its forced command. Move the binary and
    # that line points at nothing, so the phone stops being able to authenticate
    # — for a reason no error message on either end mentions.
    old=$(command -v hdp 2>/dev/null || true)
    if [ -n "$old" ] && [ "$old" != "${dir}/hdp" ]; then
        say ""
        say "  Note: hdp was already installed at ${old}."
        say "  Paired phones have that path baked into their authorized_keys line,"
        say "  so they will stop working until you re-run \`hdp pair\` and scan again."
    fi
}

main
