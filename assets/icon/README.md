# The launcher icon

Two SVGs, and every PNG under `android/app/src/main/res` is generated from them
by `tool/render_app_icon.sh`. **Edit the SVGs, not the PNGs** — the next run of
the script overwrites whatever a PNG has been changed to, without complaining.

```
sh tool/render_app_icon.sh      # then rebuild the APK
```

The script needs `rsvg-convert` (`brew install librsvg`), `magick`
(`brew install imagemagick`) and `python3` (`brew install python3`). It fails
loudly if any of the three is missing rather than shipping a stale icon.

## What the mark is

A terminal window going into a pocket. Two shapes, and the second one is the
point:

| | |
|---|---|
| **terminal** | A window with rounded top corners, cut with a shell prompt — the `>` chevron and the block cursor behind it. Flat blocks, no strokes, no gradients. |
| **pocket** | A wide pouch, straight across the top and deeply rounded at the bottom, that swallows the window's lower half. The window is *inserted*, not parked on a plinth: that is the whole name, drawn. |

The prompt is a **real hole in the alpha channel**, made with a mask. That is
not fussiness: Android 13's themed icons repaint the whole drawable in one
system colour, so a shape that was merely *coloured* to match its background
would come back as a solid blob the moment the launcher recoloured it.

The prompt is drawn at **70%** of the size it was first sketched at. At full
size it filled three quarters of the window and read as a logo rather than as a
prompt; smaller, the window has air around it and the cursor still survives the
mdpi render (48 px). Its baseline sits exactly on the pocket's mouth, so it
reads as being *in* the opening rather than floating in the window.

**White field, near-black mark.** The mark is `#13162A` — `HerdrColors.dark.ground`,
the colour the app itself opens with — so the icon and the first frame still
share a colour; it just moved from the field to the mark. It is not pure black
on purpose: flat black on flat white is the one combination that reads as a
placeholder rather than as a decision, and the near-black keeps a trace of the
indigo the whole product is built on.

The white has a twin in `android/app/src/main/res/values/colors.xml`
(`ic_launcher_background`). That resource is the background layer adaptive
launchers draw behind the mark; `tile.svg` is the whole icon for the launchers
that do not. **They have to move together** — change one alone and the app has
two different icons depending on the device.

One pleasant consequence of white: the splash screen's own background is already
white, so on those devices the tile disappears and the mark appears to float.

## How big the mark is drawn

No SVG in here sets this. `mark.svg`'s viewBox is tight to its ink and the
script decides the rest, per target:

- **Legacy tiles** (`mipmap-*/ic_launcher.png`, five densities) — the mark at
  **62%** of the tile. Nothing crops these, so this is a composition choice:
  the art fills the tile and still leaves the rounded corner empty.
- **Adaptive foreground** (`drawable/ic_launcher_foreground.png`, one 432×432
  file) — **derived on every run**. The script renders the mark, measures how
  far its ink reaches from the centre *through the pixels*, and scales it so
  that reach lands inside the 66 dp safe circle at 92%.

The first version of this file had both numbers typed in, at 70% and 60%, and
the adaptive one was wrong in a way nothing in this repo could show. Measured on
the device: the mark filled **88.9%** of the visible tile — 2 px of white at a
45 px icon, which reads as a logo pressed against the edge of its own icon. On a
launcher that masks to a circle it is worse than tight, it is a crop: that
mark's corners reached 170 px from the centre where the safe circle's radius is
132 px, so they were being shaved off.

So the adaptive scale is now computed from the artwork and then **verified**: the
script compares the ink inside the safe circle with the ink in total and fails
the run if any of it landed outside. Swapping in a differently shaped mark
cannot reintroduce the bug.

The two percentages disagree on purpose. Making them agree is the mistake: art
sized for a tile that is never cropped is too big for one that is.

## Regenerating

| output | size | contract |
|---|---|---|
| `mipmap-mdpi/ic_launcher.png` | 48 | API < 26 launchers, Android 12 splash |
| `mipmap-hdpi/ic_launcher.png` | 72 | |
| `mipmap-xhdpi/ic_launcher.png` | 96 | |
| `mipmap-xxhdpi/ic_launcher.png` | 144 | |
| `mipmap-xxxhdpi/ic_launcher.png` | 192 | |
| `drawable/ic_launcher_foreground.png` | 432 | adaptive foreground **and** the `monochrome` layer for themed icons |
| `docs/logo.png` | 384 | the README's logo — the same tile-and-mark composite, at the size a page needs rather than the size a launcher does |

`mipmap-anydpi-v26/ic_launcher.xml` ties the adaptive layers together and is
hand-written; it references `@color/ic_launcher_background`, which is the same
white as `tile.svg` and must be kept in step with it.
