# Agent brand marks

One SVG per agent, so a board of panes is scannable by brand instead of by a
letter. `lib/ui/components/agent_icon.dart` maps a herdr agent id to a file in
this directory; anything without a file here falls back to the existing
identity-colour monogram (`agentIdentityColor` + `agentGlyph` in
`../lib/ui/components/agent_visuals.dart`).

Every file is third-party artwork, so every file is recorded below with its
source URL, licence, the HTTP status it came back with, and its SHA-256.
`tool/fetch_agent_icons.sh` re-downloads all of them and fails if a single byte
differs — a vendored binary with no re-fetch path cannot be audited.

## Licence

All 18 files ship from **[@lobehub/icons-static-svg](https://github.com/lobehub/lobe-icons)**
(`license: "MIT"` in its `package.json`, verified 2026-09-11). `@latest` resolved
to **1.95.0**; the fetch script pins that version so the URLs are stable.

Brand marks remain the trademarks of their owners. Nothing here is modified,
recoloured, or re-lit; see *Presentation* below for the one thing that changes
per asset.

## Provenance

| agent id(s) | asset | source (`…/icons/<slug>.svg`) | licence | HTTP | SHA-256 |
|---|---|---|---|---|---|
| `amp`, `amp-local` | `amp.svg` | lobehub `amp-color` | MIT | 200 | `6df4cced9e35703d6263d65968985e8afdff68b61358daf9cc09fa16dd9b2aad` |
| `agy`, `antigravity`, `antigravity-cli` | `antigravity.svg` | lobehub `antigravity-color` | MIT | 200 | `652128cf55a28bb958563ee372d0bd00208d9e6fd446f523f77aafd811eef8ca` |
| `claude`, `claude-code` | `claude.svg` | lobehub `claude-color` | MIT | 200 | `a3101f3047a119aa11825ad9369510f0c472428c8c52d420e31bc62db44a8364` |
| `cline` | `cline.svg` | lobehub `cline` (mono) | MIT | 200 | `9003d2cdce82b016147b732abb4def60af55c348ba2cea2ba0b69a3c7d159b19` |
| `codex` | `codex.svg` | lobehub `codex-color` | MIT | 200 | `4a2f43ce46b5b6e3722c95088f88d26ef91e6a8c2e598e70642a1c54367386e4` |
| `copilot`, `github-copilot`, `ghcs` | `copilot.svg` | lobehub `copilot-color` | MIT | 200 | `04f15d0556fbac10a4e0f82d1560610db8b33cd04780a4f24ad3b91c4abd278d` |
| `cursor`, `cursor-agent` | `cursor.svg` | lobehub `cursor` (mono) | MIT | 200 | `0cb51bddf264ae108926fd554c063ef40fc1aac3c5c921ddb39ad184e4e5d0ef` |
| `deepseek`, `dsh`, `deepseek-tui`, `deepseek-*` | `deepseek.svg` | lobehub `deepseek-color` | MIT | 200 | `deba5f98a5c1796e20fcac3149bcd7eb8a32f0bdd04d048819400b1f28bd1439` |
| `devin`, `devin-cli` | `devin.svg` | lobehub `devin-color` | MIT | 200 | `beb58575f94fda57a6c1f9ed5624e6407bff405f55b6258b53032b674aadd8c8` |
| `gemini` | `gemini.svg` | lobehub `gemini-color` | MIT | 200 | `8ab0a9bafec11f7e69bcb9fc4ffd8f1bc927d1ddcbbb6ff36dee5ae8b5a9d602` |
| `grok`, `grok-build` | `grok.svg` | lobehub `grok` (mono) | MIT | 200 | `9175fc90c22655160231976c849f25a03b888d7cc0e04c5f1b987b659bb07c95` |
| `kimi`, `kimi-code` | `kimi.svg` | lobehub `kimi-color` | MIT | 200 | `74a7292aeb0220445d14c5d397d75760e2e8c6ed6a9e5fe4f3023471bf62a9ff` |
| `kiro`, `kiro-cli` | `kiro.svg` | lobehub `kiro-color` | MIT | 200 | `4eae4d6e818da7342c32c7d443ab7c97b93c544db9af379d5b5bf7f0a3127d66` |
| `mastracode` | `mastracode.svg` | lobehub `mastra` (mono) | MIT | 200 | `e235d4f4920b0cd1a4e050bc79aa79eedb0ed459e5321a1c5a6e72966ad5f816` |
| `opencode`, `open-code` | `opencode.svg` | lobehub `opencode` (mono) | MIT | 200 | `7cfa6e9d6726f7c9fa26c7d9aef0dfec52d20a137380454340f30f12ccbfd302` |
| `pi` | `pi.svg` | lobehub `pi` (mono) | MIT | 200 | `d82978781b824273c55473822c1f243a6ed34fc6e8c2dbfe1a90dfc66ae43ee8` |
| `qodercli`, `qoder`, `qodercn`, `qoderclicn` | `qodercli.svg` | lobehub `qoder-color` | MIT | 200 | `396596d247477e2a036c141a16ec266df7b14c0130b777a68fd04bc89af50bc8` |
| `qwen`, `qwen-code` | `qwen.svg` | lobehub `qwen-color` | MIT | 200 | `77f5768c66d08ce1d3d14e73373975c1bc0454be88c81523ddd0ffd7e2974029` |

The `deepseek` row was added 2026-09-15 and re-running the fetch script that day
reproduced the other 17 files byte for byte ("17 unchanged, 1 written"), so the
set is still pinned and still auditable.

## Ids herdr does not declare

Three ids on the `deepseek` row are not in any list herdr ships, and they are in
this directory anyway. Worth writing down, because it diverges from how every
other mark got here.

**herdr detects an agent from a manifest, and a manifest's `id` is whatever its
author typed.** The 21 manifests a live 0.9.0 loads (`server.agent_manifests`)
come from three places — `bundled`, a downloaded `remote:` registry, and a local
override — and each one is a TOML whose `id` field names the agent. So a TUI
nobody has published an integration for is detected by a manifest its own author
wrote, and it reaches the daemon under a name this app cannot look up in a
vendor list. That is the case here: the DeepSeek harness reports its panes
through a plugin of its own as `dsh`, and the same product is spelled
`deepseek-tui` (its package name) and `deepseek` elsewhere.

The mapping for it lives in `lib/ui/components/agent_icon.dart`:

- `deepseek` is the canonical id and owns the file.
- `dsh` is an explicit alias, not a prefix. Three letters that also name a Unix
  tool (`dsh`, the distributed shell) are exactly the kind of id that can arrive
  meaning something else, and a plausible wrong brand is worse than a letter —
  the same judgement that rejected Simple Icons' `hermes`.
- Every other `deepseek*` spelling (`deepseek-tui`, `deepseek-cli`, a future
  `deepseek-r2`) is folded by a vendor-prefix rule instead of a list that would
  go stale.

## Probe log — every slug attempt

Two sources were tried. Statuses below are the ones actually returned on
2026-09-11 (macOS `curl`, following redirects).

**1. Lobehub, `-color` variants** (`https://unpkg.com/@lobehub/icons-static-svg@latest/icons/<slug>-color.svg`)

| slug | status | | slug | status |
|---|---|---|---|---|
| `claude` | 200 | | `antigravity` | 200 |
| `codex` | 200 | | `gemini` | 200 |
| `copilot` | 200 | | `google` | 200 |
| `devin` | 200 | | `amp` | 200 |
| `kimi` | 200 | | `kiro` | 200 |
| `qoder` | 200 | | `deepseek` | 200 |
| `qwen` | 200 | | `mistral` | 200 |
| `openrouter` | 200 | | `openai` | **404** |

`deepseek` came back 200 here on 2026-09-11 and was recorded as "deliberately not
shipped" at the time, because no agent id resolved to it. It ships now that one
does; the 2026-09-15 fetch returned the same slug and the bytes in the table
above.

**2. Simple Icons v13** (`https://cdn.jsdelivr.net/npm/simple-icons@13/icons/<slug>.svg`)

| slug | status | note |
|---|---|---|
| `x` | 200 | X / Twitter |
| `hermes` | 200 | **wrong brand** — see below |
| `amp` | 200 | **wrong brand** — see below |
| `githubcopilot` | 200 | GitHub Copilot |
| `claude` | 200 | |
| `anthropic` | 200 | |
| `openai` | 200 | |
| `googlegemini` | 200 | |
| `ollama` | 200 | |

**3. Lobehub, plain (monochrome) variants** — tried after the `-color` 404s,
because a plain file often exists where a coloured one does not. This is where
`cursor`, `cline`, `opencode`, `grok` and `mastracode` came from.

| slug | status | | slug | status |
|---|---|---|---|---|
| `grok` | 200 | | `pi` | 200 |
| `xai` | 200 | | `amp` | 200 |
| `cursor` | 200 | | `kiro` | 200 |
| `opencode` | 200 | | `mastra` | 200 |
| `cline` | 200 | | `windsurf` | 200 |
| `hermes` | **404** | | | |

**4. Existence checked against the sources' own indexes instead of one probe per
guess** (one request each, rather than a dozen blind ones):

- `https://unpkg.com/@lobehub/icons-static-svg@latest/?meta` → 669 plain slugs,
  237 of them with a `-color` variant.
- `https://cdn.jsdelivr.net/npm/simple-icons@13/_data/simple-icons.json` →
  3296 icons (slug = title, lowercased, non-alphanumerics stripped).

Absent from **both** indexes: `kilo`, `droid`, `factory`, `mastracode` (as a
slug), `aider`, `omp`, `hermes`, `cursor`/`grok`/`opencode`/`cline`/`windsurf`/
`pi`/`xai` under Simple Icons.

## Agents on the monogram fallback, and what was tried first

Six ids herdr can report have no mark here, plus everything future herdr adds.

| agent id | what was tried | why the fallback |
|---|---|---|
| `omp` | both indexes; no `omp` slug anywhere | no published mark under any spelling |
| `droid` | lobehub `droid`, `factory`; both absent from the index | Factory's Droid has no logo in either set |
| `kilo` | lobehub `kilo`, simple-icons `kilo` | absent from both |
| `hermes` | lobehub `hermes` → **404**; simple-icons `hermes` → 200 but the icon's own `source` field is `https://www.myhermes.de/…`, i.e. the German parcel company, not a coding agent | **the only 200 for `hermes` is the wrong brand.** One product's mark on another product's pane is worse than a letter, so this is a deliberate rejection of a licence-clean asset |
| `maki`, `muse` | lobehub; absent | manifests exist in the herdr 0.9.0 binary, no integration installs them yet, no mark published |

`hermes` and `amp` are the two traps worth remembering: Simple Icons **does**
have both slugs, and both are the wrong product (`hermes` = Hermes Germany,
`amp` = the AMP web framework at `amp.dev`). The Sourcegraph Amp mark shipped
here is lobehub's `amp-color` (`#F34E3F`), not Simple Icons' `amp`.

Deliberately **not** shipped, to avoid dead assets: `openai`, `google`,
`mistral`, `openrouter`, `anthropic`, `ollama`, `x`, `xai`, `windsurf`.
None of them is an agent id herdr reports. (`xai` is the same product as `grok`
and carries `<title>Grok</title>`; `grok.svg` is used. `deepseek` was on this
list until an id resolved to it — see *Ids herdr does not declare* above.)

## Presentation — one treatment for all of them

**EVERY mark is drawn as a solid white element on a chip carrying the agent's
identity gradient.** Not the vendors' own colours. The history matters here,
because this is the THIRD treatment and the first two are worth not repeating.

### 1. As published — reverted

The first version rendered each asset exactly as it came, and the result was not
a set:

| what went wrong | assets |
|---|---|
| pure black — **literally 0.0000 mean ink on a dark ground** | `cline` `cursor` `grok` `mastracode` `opencode` `pi` |
| white — invisible on a light ground | `kimi` |
| two halves needing opposite grounds, so it lost content either way | `qodercli` |
| brand **gradients**, four of them in four unrelated palettes | `codex` `copilot` `gemini` `qwen` |

Seventeen icons ended up with nine rules, and the board read as a collection of
logos rather than a system.

### 2. White plate, black ink — worked, but achromatic

One rule instead of seventeen exceptions, and it held. What it gave up was the
one thing the design language sets aside for decorative colour: the agent
identity itself (`docs/research/03-design-language.md`: *"Decorative colour is
allowed in exactly one place: the agent-identity gradient"*). The app spent its
only sanctioned colour slot on white.

### 3. Identity gradient, white ink — current

The chip carries a gradient from `lib/domain/agent/agent_identity.dart`
(`claude` magenta, `codex` orange, `gemini` indigo, `pi` teal, violet for
everything else) and the mark is white on it.

**What makes this work when (1) did not is that the colour is OURS.** It comes
from the design language's own identity vocabulary, not from seventeen vendors,
so it is one palette rather than seventeen. Every combination is guaranteed to
carry white ink by construction — `identityFor` pushes both gradient ends until
white clears 3.0:1, which is how `codex` (`#E8923C`, 2.45:1 as published) and
`pi` (`#3FB6A8`, 2.50:1) are corrected without anyone restating a hue by hand.

The vendor files still supply only the SHAPE. Everything the first attempt
tripped over is now irrelevant: a pure-black logo and a pure-white logo both
render as white silhouettes, `qodercli`'s two halves no longer need opposite
grounds because neither half keeps its colour, and the four brand gradients are
collapsed at paint time rather than by editing artwork.

**Flattening happens at paint time, not in the files.** `AgentIcon` applies
`ColorFilter.mode(white, BlendMode.srcIn)`, which collapses fills, strokes and
gradients to a single colour in one pass. Editing the SVGs instead would mean
modifying vendor artwork and invalidating every SHA-256 above.

**The chip is not themed.** A chip whose gradient flipped with the mode would
need a second, darker vocabulary to stay legible on, and one agent's identity
would become two identities.

Brand marks remain the trademarks of their owners; they are identified here, not
redrawn, and the flat treatment is the ordinary monochrome-usage convention
rather than a modification of the marks themselves.

## Gradients

Four of these marks (`codex`, `copilot`, `gemini`, `qwen`) contain the brand's
own gradient, and they are shipped with it intact — the files are the vendors'
artwork and are not edited. It never reaches the screen: `AgentIcon` draws every
mark with `BlendMode.srcIn`, so a gradient and a flat fill render identically.
The gradient in the CHIP comes from our own identity vocabulary, which is a
different thing in a different file.

## Re-fetching

```sh
tool/fetch_agent_icons.sh            # re-download everything, verify every SHA-256
tool/fetch_agent_icons.sh --probe    # re-print the HTTP status of every candidate slug
```

The script is the only sanctioned way to change this directory: it fails on an
HTTP mismatch, on a body that is not an SVG, and on any byte that differs from
the hashes above.

## How these were checked before shipping

Not by reading the SVGs. All 18 were rendered through **the same pipeline the
app uses** — `flutter_svg` → `vector_graphics` — at the real 18 px, on both card
grounds, and looked at. Two things that guessing would have missed:

- **`antigravity.svg` uses 11 gaussian `<filter>`s** (it is a glow logo) and
  `flutter_svg` cannot render `<filter>`; it warns `unhandled element <filter/>`
  and drops them. The arch still draws, unblurred — at 18 px the blur was never
  visible anyway. This is the only asset with an unrenderable element, and it
  was confirmed by looking, not by trusting the warning.
- The four gradient marks (`codex`, `copilot`, `gemini`, `qwen`) and the plates
  all resolve correctly in dark and light.

`deepseek.svg` was checked the same way on 2026-09-15, next to `claude`, `codex`,
`cursor`, `pi` and `kimi` at 18 px on both grounds: it is one flat `<path>`, it
needs no special case, and the whale still reads as a whale at board size — it
is a wide mark, so it fills more of the chip's width than `cursor`'s cube does,
which is the ordinary result of the shared 62 % inset rather than a reason for a
per-asset scale. `dsh` and `deepseek-tui` render it identically to `deepseek`,
which is the aliasing being visible rather than inferable.

The harness is 20 lines and worth re-running after any asset change — a
throwaway `flutter test` file (never committed) that compiles each asset and
draws it on a `PictureRecorder`:

```dart
final info = await vg.loadPicture(
  SvgBytesLoader(Uint8List.fromList(File(asset).readAsBytesSync())),
  null,
);
// ground, then the identity chip (always drawn, see `_Plate`), then:
// canvas.scale(size * 0.62 / info.size.width); canvas.drawPicture(info.picture);
final image = await recorder.endRecording().toImage(px, px);
File(out).writeAsBytesSync(
  (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List(),
);
```

`test/ui/agent_icon_test.dart` keeps the cheap half of this permanently: it
compiles every asset and asserts a non-zero picture, so an unparseable SVG can
never ship even though nobody is looking at pixels in CI.
