# Bundled fonts

Two files that behave as ONE grid. Read this before replacing either of them.

| file | family | covers | SHA-256 (first 16) |
|---|---|---|---|
| `IosevkaNerdFontMono-Regular.ttf` | `IosevkaNerdFontMono` | Latin + Nerd Font icons | `f803b8eac0897b94` |
| `NotoSansMonoCJKsc-Regular.otf` | `NotoSansMonoCJKsc` | Han | `ec04cc376b34887c` |

## Licence

- **Iosevka** — SIL Open Font License 1.1. <https://github.com/be5invis/Iosevka>
- **Noto Sans Mono CJK SC** — SIL Open Font License 1.1. <https://github.com/notofonts/noto-cjk>

Both permit bundling and redistribution. Neither file has been modified.

Iosevka is the **Mono** Nerd Font build, not the plain one: the plain variant
gives icons a double-width advance, which puts every prompt separator off the
grid. The `Mono` build keeps every glyph on one advance.

## Why these two, and what a replacement must satisfy

A terminal is a fixed grid. A full-width Han glyph must occupy **exactly two**
cells, and whether that holds is a property of the fonts' ADVANCES rather than of
the platform. Android's own monospace family has no CJK at all, so the system
falls back to a *proportional* CJK face and the right edge of every mixed line
goes ragged.

Iosevka has **no Han coverage at all** — 18,239 glyphs and not one Chinese
character — so Chinese is served by Noto. They are only allowed to be paired
because the numbers agree, measured from the font files with a cmap/hmtx probe:

```
Iosevka  'M'   0.5000 em        Noto  'M'   0.5000 em
                                Noto  '汉'  1.0000 em   ->  exactly 2 x 0.5 em
```

So the rule for a replacement is **not** "find a CJK monospace" but:

> find one whose Han advance is exactly twice the Latin advance you already have.

This is not hypothetical. The project previously bundled **Maple Mono NF CN**
alone, which also worked (its 'M' is 0.6 em and its Han 1.2 em — again exactly
2.0). It was replaced for the Latin face, not the grid. What fails is *mixing*
them: Iosevka's 0.5 em Latin beside Maple's 1.2 em Han measures **2.4**, and
every Chinese character drifts out of its cell.

`test/ui/terminal_font_metrics_test.dart` asserts all of this through Flutter's
own text layout — the path the app renders through — rather than trusting these
numbers. If you change a font, that test is what will tell you.
