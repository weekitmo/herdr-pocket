#!/usr/bin/env bash
#
# Re-download and verify every brand mark in assets/agent_icons/.
#
# WHY this exists: these SVGs are checked-in third-party binaries. A vendored
# file with no re-fetch path cannot be audited — nobody can tell whether it is
# the real upstream logo, an edited one, or an error page saved under an .svg
# name. Running this script either reproduces the exact bytes recorded in
# assets/agent_icons/README.md or fails loudly.
#
# Usage:
#   tool/fetch_agent_icons.sh            download, then verify against pinned SHA-256
#   tool/fetch_agent_icons.sh --probe    re-print the HTTP status of every candidate slug
#
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="assets/agent_icons"

# Pinned on purpose. `@latest` resolved to 1.95.0 on 2026-09-11; a floating tag
# plus a pinned hash is a combination that breaks on someone's unrelated Tuesday
# without telling them why.
LOBEHUB_VERSION='1.95.0'
LOBEHUB_BASE="https://unpkg.com/@lobehub/icons-static-svg@${LOBEHUB_VERSION}/icons"

# asset file | upstream slug | sha256
MANIFEST=(
  'amp.svg|amp-color|6df4cced9e35703d6263d65968985e8afdff68b61358daf9cc09fa16dd9b2aad'
  'antigravity.svg|antigravity-color|652128cf55a28bb958563ee372d0bd00208d9e6fd446f523f77aafd811eef8ca'
  'claude.svg|claude-color|a3101f3047a119aa11825ad9369510f0c472428c8c52d420e31bc62db44a8364'
  'cline.svg|cline|9003d2cdce82b016147b732abb4def60af55c348ba2cea2ba0b69a3c7d159b19'
  'codex.svg|codex-color|4a2f43ce46b5b6e3722c95088f88d26ef91e6a8c2e598e70642a1c54367386e4'
  'copilot.svg|copilot-color|04f15d0556fbac10a4e0f82d1560610db8b33cd04780a4f24ad3b91c4abd278d'
  'cursor.svg|cursor|0cb51bddf264ae108926fd554c063ef40fc1aac3c5c921ddb39ad184e4e5d0ef'
  'deepseek.svg|deepseek-color|deba5f98a5c1796e20fcac3149bcd7eb8a32f0bdd04d048819400b1f28bd1439'
  'devin.svg|devin-color|beb58575f94fda57a6c1f9ed5624e6407bff405f55b6258b53032b674aadd8c8'
  'gemini.svg|gemini-color|8ab0a9bafec11f7e69bcb9fc4ffd8f1bc927d1ddcbbb6ff36dee5ae8b5a9d602'
  'grok.svg|grok|9175fc90c22655160231976c849f25a03b888d7cc0e04c5f1b987b659bb07c95'
  'kimi.svg|kimi-color|74a7292aeb0220445d14c5d397d75760e2e8c6ed6a9e5fe4f3023471bf62a9ff'
  'kiro.svg|kiro-color|4eae4d6e818da7342c32c7d443ab7c97b93c544db9af379d5b5bf7f0a3127d66'
  'mastracode.svg|mastra|e235d4f4920b0cd1a4e050bc79aa79eedb0ed459e5321a1c5a6e72966ad5f816'
  'opencode.svg|opencode|7cfa6e9d6726f7c9fa26c7d9aef0dfec52d20a137380454340f30f12ccbfd302'
  'pi.svg|pi|d82978781b824273c55473822c1f243a6ed34fc6e8c2dbfe1a90dfc66ae43ee8'
  'qodercli.svg|qoder-color|396596d247477e2a036c141a16ec266df7b14c0130b777a68fd04bc89af50bc8'
  'qwen.svg|qwen-color|77f5768c66d08ce1d3d14e73373975c1bc0454be88c81523ddd0ffd7e2974029'
)

# Every slug attempt recorded in README.md, including the ones that must fail.
# label|url
PROBES=(
  'lobehub/claude-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/claude-color.svg'
  'lobehub/codex-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/codex-color.svg'
  'lobehub/copilot-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/copilot-color.svg'
  'lobehub/devin-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/devin-color.svg'
  'lobehub/kimi-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/kimi-color.svg'
  'lobehub/qoder-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/qoder-color.svg'
  'lobehub/qwen-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/qwen-color.svg'
  'lobehub/antigravity-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/antigravity-color.svg'
  'lobehub/gemini-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/gemini-color.svg'
  'lobehub/google-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/google-color.svg'
  'lobehub/amp-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/amp-color.svg'
  'lobehub/kiro-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/kiro-color.svg'
  'lobehub/deepseek-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/deepseek-color.svg'
  'lobehub/mistral-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/mistral-color.svg'
  'lobehub/openrouter-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/openrouter-color.svg'
  'lobehub/openai-color|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/openai-color.svg'
  'lobehub/grok|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/grok.svg'
  'lobehub/xai|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/xai.svg'
  'lobehub/cursor|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/cursor.svg'
  'lobehub/opencode|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/opencode.svg'
  'lobehub/cline|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/cline.svg'
  'lobehub/mastra|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/mastra.svg'
  'lobehub/windsurf|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/windsurf.svg'
  'lobehub/pi|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/pi.svg'
  'lobehub/hermes|https://unpkg.com/@lobehub/icons-static-svg@latest/icons/hermes.svg'
  'simple-icons/x|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/x.svg'
  'simple-icons/hermes|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/hermes.svg'
  'simple-icons/amp|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/amp.svg'
  'simple-icons/githubcopilot|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/githubcopilot.svg'
  'simple-icons/claude|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/claude.svg'
  'simple-icons/anthropic|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/anthropic.svg'
  'simple-icons/openai|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/openai.svg'
  'simple-icons/googlegemini|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/googlegemini.svg'
  'simple-icons/ollama|https://cdn.jsdelivr.net/npm/simple-icons@13/icons/ollama.svg'
)

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    # macOS. `shasum` ships with the OS, `sha256sum` does not.
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

status_of() {
  curl -sS -o /dev/null -w '%{http_code}' -L --max-time 30 "$1" 2>/dev/null || echo 'ERR'
}

cmd_probe() {
  printf '%-28s %s\n' 'slug' 'status'
  for row in "${PROBES[@]}"; do
    printf '%-28s %s\n' "${row%%|*}" "$(status_of "${row#*|}")"
  done
  echo
  echo 'Expected to be 200: everything except lobehub/openai-color (404) and'
  echo 'lobehub/hermes (404). A 200 for simple-icons/hermes is the known trap:'
  echo 'that slug is Hermes Germany (myhermes.de), not the hermes agent.'
}

cmd_fetch() {
  workdir=$(mktemp -d)
  # `${workdir:-}`: the trap fires after this function's scope has ended, where a
  # `local` would already be gone and `set -u` would turn cleanup into a failure.
  trap 'rm -rf "${workdir:-}"' EXIT

  if [ ! -d "$OUT_DIR" ]; then
    echo "FAIL  $OUT_DIR does not exist (run from the project root)" >&2
    exit 1
  fi

  local failures=0 unchanged=0 updated=0
  for row in "${MANIFEST[@]}"; do
    local file slug want tmp got code
    file="${row%%|*}"
    slug="$(printf '%s' "${row#*|}" | cut -d'|' -f1)"
    want="${row##*|}"
    tmp="$workdir/$file"

    code=$(curl -sS -o "$tmp" -w '%{http_code}' -L --max-time 30 "$LOBEHUB_BASE/$slug.svg") || code='ERR'
    if [ "$code" != '200' ]; then
      printf 'FAIL  %-18s HTTP %s\n' "$file" "$code" >&2
      failures=$((failures + 1))
      continue
    fi

    # An error page saved under an .svg name is the classic silent corruption.
    if ! head -c 4096 "$tmp" | tr -d '[:space:]' | grep -q '^<svg'; then
      printf 'FAIL  %-18s body is not an SVG\n' "$file" >&2
      failures=$((failures + 1))
      continue
    fi

    got=$(sha256_of "$tmp")
    if [ "$got" != "$want" ]; then
      printf 'FAIL  %-18s sha256 %s\n      expected %s\n' "$file" "$got" "$want" >&2
      failures=$((failures + 1))
      continue
    fi

    if [ -f "$OUT_DIR/$file" ] && [ "$(sha256_of "$OUT_DIR/$file")" = "$want" ]; then
      printf 'ok    %-18s unchanged\n' "$file"
      unchanged=$((unchanged + 1))
    else
      cp "$tmp" "$OUT_DIR/$file"
      printf 'ok    %-18s written\n' "$file"
      updated=$((updated + 1))
    fi
  done

  echo
  echo "$unchanged unchanged, $updated written, $failures failed (lobehub ${LOBEHUB_VERSION})"
  [ "$failures" -eq 0 ] || exit 1
}

case "${1:-}" in
  --probe) cmd_probe ;;
  ''|--fetch) cmd_fetch ;;
  *) echo "usage: $0 [--probe]" >&2; exit 2 ;;
esac
