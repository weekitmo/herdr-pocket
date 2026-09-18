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

/// The zoom at which the pane's rows fill the box, never below [zoom].
///
/// THE OTHER HALF OF [rowsToRequest]. That function asks the daemon for the
/// pane's own rows — a smaller request would crop the pane's bottom — which
/// leaves the phone with more rows of screen than the pane has content: 48 rows
/// of desktop pane in a box that fits 66, measured on the phone. The spare rows
/// have to go somewhere, and both ends read as a bug (an empty band under the
/// terminal, or above it).
///
/// So the text is scaled up instead, until the pane's own rows fill the box.
/// The trade is horizontal: a bigger cell means fewer columns of a pane that is
/// wider than the phone, so the user sees less of each line — which is why the
/// fit is opt-in on the device (the user asked for 铺满), why it never scales
/// DOWN ([zoom] is a floor), and why the cap keeps a very short pane (a 6-row
/// spinner, say) from producing a wall of giant text.
///
/// [boxRows] is how many rows the box holds at [zoom], i.e. already in cells
/// rather than pixels — the same unit as [paneRows].
double filledZoom({
  required double zoom,
  required int paneRows,
  required double boxRows,
  required double maxZoom,
}) {
  if (paneRows <= 0 || boxRows <= paneRows) return zoom;
  final filled = zoom * boxRows / paneRows * _fillSlack;
  return filled > maxZoom ? maxZoom : filled;
}

/// A hair less than a perfect fit, as a fraction.
///
/// THE PERFECT FIT IS A KNIFE EDGE. `boxRows` is `height / cellHeight` as a
/// double and the layout rounds it with `floor`, so a fill computed to land
/// exactly on the box's edge is decided to be one row too tall by a floated
/// pixel — and the first line of the pane is cropped for no reason. Half a
/// percent is a twentieth of a logical pixel of text and takes the edge away.
const double _fillSlack = 0.995;

/// The first buffer row to draw at the top of the surface, and how many blank
/// rows go above it.
///
/// ## The two directions, because the box and the pane disagree in both
///
/// The daemon renders a pane at whatever geometry the client asks for, so the
/// phone asks for the pane's own rows — see [rowsToRequest]. On a phone that is
/// SHORTER than the pane (the keyboard is up, or the pane is a tall desktop
/// window), the box cannot hold the frame and the frame's BOTTOM is the part
/// worth keeping: that is where the prompt and every TUI's input line live.
///
/// On a phone that is TALLER than the pane — which is the ordinary state of a
/// desktop pane mirrored onto a tall phone, measured at 48 rows of pane in 66
/// rows of box — the frame cannot fill the box, and the question is where the
/// spare rows go. They go at the TOP, which pins the pane's last row just above
/// the key bar. That is not cosmetic: it is the same promise [rowsToRequest]
/// makes when it refuses to pad the frame from the daemon ("the extra rows come
/// back as blank padding, which pushes the pane's real last line further from
/// the key bar"), and it is what the phone reported as missing — after the
/// keyboard or the chat window closed, the picture sat against the top of the
/// screen with a band of empty terminal under it.
///
/// [skip] is how many rows of the frame fall off its top; [pad] is how many
/// blank rows sit above it. At most one is ever non-zero.
({int skip, int pad}) framePlacement({
  required int frameRows,
  required int boxRows,
  required bool following,
}) {
  if (frameRows <= 0 || boxRows <= 0) return (skip: 0, pad: 0);
  final excess = frameRows - boxRows;
  if (excess >= 0) {
    // Taller than the box: show the bottom. The exception is a reader who has
    // scrolled back — the frame the daemon sent IS the region they asked for,
    // and shifting it would move the text out from under the eye that asked
    // for it.
    return (skip: following ? excess : 0, pad: 0);
  }
  // Shorter than the box: the spare rows are above the frame, and the pane's
  // last row sits on the box's last row. Nothing is cropped either way, so the
  // reader's position does not matter here — the frame is entirely visible.
  return (skip: 0, pad: -excess);
}
