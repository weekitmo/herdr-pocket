# UI icons

Eight icons for the app's own chrome — the dock, the terminal's navbar, and the
board's machine entry. One SVG each.

## Why they are vendored with holes in them

Every published IconPark file has a colour already in it (its own blue). This app
ships twelve colour schemes, so a baked-in blue is wrong in eleven of them.

IconPark's source modules happen to parameterise every fill already —
`props.colors[0]`, `props.colors[1]`, … — so **`tool/fetch_ui_icons.py` resolves
those to `__C0__`..`__C3__` and nothing else**. The app substitutes real colours
at paint time. The files here contain no colour at all, which is why they are not
simply downloaded: a downloaded file would be a *decision* about colour that this
project has not made yet.

| file | surface | colour slots |
|---|---|---|
| `Workbench.svg` | dock, Board tab | 1 |
| `AllApplication.svg` | dock, Workspaces tab | 2 |
| `SettingTwo.svg` | dock, Settings tab | 4 |
| `Paperclip.svg` | terminal navbar, attach | 1 |
| `BlocksAndArrows.svg` | terminal navbar, pane switcher | 2 |
| `LayoutFour.svg` | terminal navbar, split layout | 3 |
| `MoreTwo.svg` | terminal navbar, overflow | 3 |
| `Server.svg` | board navbar, machine entry | 3 |

**The slot counts are not uniform and that is the honest state of this set.**
`Paperclip` and `Workbench` have a single slot, so they will stay flat whatever
palette they are handed, while `SettingTwo` has four. A dock built from these is
not uniformly colourful.

## Licence

From **[@icon-park/svg](https://github.com/bytedance/IconPark)**, Apache-2.0
(`LICENSE` in that package, Apache License 2.0, verified 2026-09-14). `@latest`
resolved to **1.4.2**; the script pins that version so the URLs are stable.

## Re-fetching

```sh
python3 tool/fetch_ui_icons.py           # fetch, verify, write
python3 tool/fetch_ui_icons.py --check   # verify only, write nothing
```

The script records a SHA-256 per file in `manifest.json`, removes anything in
this directory that the manifest no longer lists, and fails if a slot-less icon
would have been silently shipped as unthemed.
