/// What the phone asks the daemon to render, and which slice of it to show.
///
/// ## The measurement this file exists for
///
/// The daemon renders a pane at whatever geometry the client asks for. When
/// that geometry is SMALLER than the pane it **crops from the top-left**, and
/// it does not resize the pane's pty to match — measured against herdr 0.9.0
/// with a 46-row, 164-column pane:
///
/// ```text
/// observe --cols 164 --rows 46    → the pane's own screen
/// observe --cols 164 --rows 20    → rows 1-20 of that screen, composer gone
/// observe --cols 164 --rows 120   → the pane's screen, then blank rows
/// ```
///
/// and `pane.list` reports `viewport_rows: 46` throughout: nothing reflows to
/// fit the smaller window, so asking for fewer rows than the pane has is the
/// same as throwing the bottom of it away. The bottom is where every
/// full-screen tool keeps the line you are typing into — which is how the bug
/// this file was written for presented itself: the moment the soft keyboard
/// opened, the box shrank, more rows were being asked for than the pane had,
/// and the agent's input box vanished.
///
/// Two rules follow, and they are the whole module:
///
///  1. **Ask for the pane's own height, not the box's.** The window into the
///     pane is then independent of the keyboard, so opening it costs no
///     re-render at all — and no client-side guess about what the pane is.
///  2. **Show the BOTTOM of the frame when it does not fit.** A phone box that
///     cannot hold the whole pane is showing a magnified window onto it, and
///     the interesting end of a terminal is the bottom one.
library;

/// How many rows to ask the daemon to render.
///
/// [paneRows] is the pane's own height in cells (`pane.list`'s
/// `scroll.viewport_rows`), and null when it is not known — a tree that could
/// not be read, or a pane that has just appeared. Unknown falls back to
/// [boxRows], which is the old behaviour: correct, but the bottom of the pane
/// is at the mercy of the keyboard.
///
/// COLUMNS ARE DELIBERATELY NOT HERE. A pane that is wider than the phone is
/// cropped horizontally on purpose — text cannot be re-wrapped on the phone, so
/// the honest thing to show is a readable window into the real line, not a
/// reflowed copy of it.
int rowsToRequest({required int paneRows, required int boxRows}) {
  if (paneRows <= 0) return boxRows;
  return paneRows;
}

/// The first buffer row to draw at the top of the surface.
///
/// Zero while the frame fits — the pane's top stays at the top — and the
/// difference when it does not: the frame's LAST [boxRows] rows are the ones
/// that reach the screen, so the cursor, the prompt and every TUI's composer
/// stay above the key bar instead of sliding off the bottom.
///
/// [following] is false when the user has scrolled back into history, and then
/// the shift is zero: the frame the daemon sent IS the region they asked for,
/// and its top is where they are reading.
int firstVisibleRow({
  required int frameRows,
  required int boxRows,
  required bool following,
}) {
  if (!following) return 0;
  if (frameRows <= 0 || boxRows <= 0) return 0;
  return frameRows > boxRows ? frameRows - boxRows : 0;
}
