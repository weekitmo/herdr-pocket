import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/domain/terminal/key_bar.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';
import 'package:herdr_pocket/ui/pages/terminal/terminal_render.dart';

/// The strip of keys under a terminal, and the panel holding the rest of them.
///
/// WHY IT IS ITS OWN FILE. Two screens put a terminal on the phone now — the
/// herdr pane mirror, and a plain PTY on the host — and they have to offer the
/// SAME keys with the same sticky-modifier behaviour, because the user does not
/// experience them as two features. A second copy of this strip would be a copy
/// of the fan, the arc reveal and the icon set along with it, and the two would
/// drift the first time one of them grew a key.
///
/// Public names, private everything else: [KeyStrip] and [KeyFan] are built by
/// both pages, while the caps and the clipper are this file's own business.
///
/// THE STATE IS NOT HERE. [KeyBarState] lives in `domain/terminal/key_bar.dart`
/// and this is only a view of it, because an armed `Ctrl` has to apply to the
/// phone's own soft keyboard as well, not merely to the dozen keys drawn here.

class KeyStrip extends StatelessWidget {
  const KeyStrip({
    required this.keys,
    required this.state,
    required this.onTap,
    required this.palette,
    required this.enabled,
    required this.onKeyboard,
    required this.keyboardUp,
    required this.onExpand,
    required this.expanded,
    required this.onComposer,
    required this.composerOpen,
    required this.composerEnabled,
    super.key,
  });

  /// Which keys to offer, in order. Comes from Settings.
  final List<SoftKey> keys;
  final KeyBarState state;
  final ValueChanged<SoftKey> onTap;
  final TerminalColors palette;
  final bool enabled;

  /// Raises or puts away the input method.
  final VoidCallback onKeyboard;
  final bool keyboardUp;

  /// Opens the panel holding the rest of the catalogue.
  final VoidCallback onExpand;
  final bool expanded;

  /// Opens and closes the chat window.
  final VoidCallback onComposer;
  final bool composerOpen;

  /// Whether the chat window is offered at all. Off means the button is gone
  /// rather than dead: see `SettingsState.composerEnabled`.
  final bool composerEnabled;

  @override
  Widget build(BuildContext context) {
    // TWO BUTTONS PINNED TO THE RIGHT, outside the scroller.
    //
    // The bar scrolls horizontally, and anything inside that scroller can be
    // scrolled off the end — which is precisely the wrong property for the two
    // controls that have to be reachable at all times: "give me a keyboard",
    // and "show me everything else". Pinned, they are the only two things on
    // this row whose position a user can learn.
    return Container(
      height: TerminalPageMetrics.keyBarHeight,
      color: palette.background,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (context, i) {
                final key = keys[i];
                return _KeyCap(
                  cap: key,
                  palette: palette,
                  armed: key.isModifier && state.isArmed(_modifierOf(key)),
                  enabled: enabled,
                  onTap: () => onTap(key),
                );
              },
            ),
          ),
          if (composerEnabled)
            _BarButton(
              palette: palette,
              selected: composerOpen,
              onTap: onComposer,
              semanticsLabel: AppLocalizations.of(context).composerOpen,
              icon: CupertinoIcons.chat_bubble,
            ),
          _BarButton(
            palette: palette,
            selected: keyboardUp,
            onTap: onKeyboard,
            semanticsLabel: keyboardUp
                ? AppLocalizations.of(context).terminalHideKeyboard
                : AppLocalizations.of(context).terminalShowKeyboard,
            icon: CupertinoIcons.keyboard,
          ),
          _BarButton(
            palette: palette,
            selected: expanded,
            onTap: onExpand,
            semanticsLabel: AppLocalizations.of(context).terminalAllKeys,
            icon: CupertinoIcons.square_grid_3x2,
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
    );
  }

  static TerminalModifier _modifierOf(SoftKey key) => switch (key) {
    SoftKey.ctrl => TerminalModifier.ctrl,
    SoftKey.alt => TerminalModifier.alt,
    SoftKey.shift => TerminalModifier.shift,
    _ => throw ArgumentError('$key is not a modifier'),
  };
}

/// One of the two pinned controls at the end of the bar.
///
/// An ICON, unlike every cap beside it, and the difference is meaningful rather
/// than cosmetic: a cap sends a byte to the machine, and these two do something
/// to this phone. Drawing them as words in the same chips as `esc` and `C-c`
/// would put "keyboard" in a list of things the terminal understands, which it
/// is not.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.palette,
    required this.selected,
    required this.onTap,
    required this.semanticsLabel,
    required this.icon,
  });

  final TerminalColors palette;
  final bool selected;
  final VoidCallback onTap;
  final String semanticsLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 40,
          height: TerminalPageMetrics.keyBarHeight,
          alignment: Alignment.center,
          child: Container(
            width: 30,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? palette.cursor.withValues(alpha: 0.22)
                  : colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(
                color: selected ? palette.cursor : colors.hairline,
              ),
            ),
            child: Icon(
              icon,
              size: 16,
              color: selected ? palette.cursor : colors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Identifies the expanded key panel.
///
/// A public key rather than a private type because the panel's whole point is
/// that it duplicates the bar: without a handle on it, any test of "tap Ctrl in
/// the panel" is a test of "tap one of the two widgets that say Ctrl".
const Key keyFanKey = ValueKey('terminal-key-fan');

/// The measurements the bar and the panel above it share.
///
/// Two widgets, one number: the panel floats exactly [keyBarHeight] above the
/// bottom of the stack, and if the bar's height lived in two places the panel
/// would slowly drift onto it.
abstract final class TerminalPageMetrics {
  static const double keyBarHeight = 46;
}

/// Every key in the catalogue, in a panel that arcs out of the toolbar.
///
/// WHY THIS EXISTS. The bar is a horizontal scroller and the catalogue is
/// twenty-four keys long, so most of it is off-screen — reachable, but only by
/// a scroll gesture nobody performs while an agent is waiting. The alternative
/// — a bar wide enough for everything — would be a wall of chips across the
/// bottom third of the terminal.
///
/// THE EXPANSION IS AN ARC, TWICE OVER, and that is the whole visual idea:
/// the panel is revealed by a circle growing out of the corner it is anchored
/// to, and each cap travels to its place along a bowed path rather than
/// straight to it. Caps land in a stagger so the panel assembles instead of
/// appearing — which is what makes the relationship between the button and the
/// panel legible in the 200 milliseconds before the user starts reading it.
class KeyFan extends StatefulWidget {
  const KeyFan({
    required this.keys,
    required this.state,
    required this.palette,
    required this.colors,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final List<SoftKey> keys;
  final KeyBarState state;
  final TerminalColors palette;
  final HerdrColors colors;
  final bool enabled;
  final ValueChanged<SoftKey> onTap;

  @override
  State<KeyFan> createState() => KeyFanState();
}

class KeyFanState extends State<KeyFan> with SingleTickerProviderStateMixin {
  /// Long enough to be seen, short enough that it is never in the way.
  ///
  /// A panel that takes half a second to assemble is a panel the user waits
  /// for; this one is finished before the eye has finished moving to it, and it
  /// still reads as motion rather than as a jump cut.
  static const Duration _duration = Duration(milliseconds: 210);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colours = widget.colors;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return ClipPath(
          clipper: _ArcRevealClipper(_controller.value),
          child: Opacity(opacity: t.clamp(0, 1), child: child),
        );
      },
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(
          color: colours.surface,
          borderRadius: BorderRadius.circular(Radii.uniform),
          border: Border.all(color: colours.hairline),
          boxShadow: Elevation.card(colours),
        ),
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (var i = 0; i < widget.keys.length; i++)
              _FanKey(
                progress: _controller,
                index: i,
                // The arc: half a second of stagger across the whole panel, so
                // the caps leave the corner in order.
                delay: i * 0.012,
                child: _KeyCap(
                  cap: widget.keys[i],
                  palette: widget.palette,
                  armed: widget.keys[i].isModifier &&
                      widget.state.isArmed(_modifierFor(widget.keys[i])),
                  enabled: widget.enabled,
                  onTap: () => widget.onTap(widget.keys[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static TerminalModifier _modifierFor(SoftKey key) => switch (key) {
    SoftKey.ctrl => TerminalModifier.ctrl,
    SoftKey.alt => TerminalModifier.alt,
    SoftKey.shift => TerminalModifier.shift,
    _ => throw ArgumentError('$key is not a modifier'),
  };
}

/// One cap's journey out of the button's corner.
///
/// The path is a QUADRATIC BOW rather than a straight line: the cap leaves the
/// anchor heading sideways and arrives heading up, which is the difference
/// between a panel that fans open and a grid that fades in. The bow is a
/// fraction of the distance travelled, so a cap near the anchor moves almost
/// straight and the far corner swings the most — the same way a fan does.
class _FanKey extends StatelessWidget {
  const _FanKey({
    required this.progress,
    required this.index,
    required this.delay,
    required this.child,
  });

  final Animation<double> progress;
  final int index;
  final double delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, inner) {
        // Each cap has its own slice of the timeline, and its own curve: the
        // overshoot on the scale is what makes the last few caps feel like they
        // snapped into place rather than slid.
        final t = ((progress.value - delay) / (1 - delay)).clamp(0.0, 1.0);
        final eased = Curves.easeOutBack.transform(t);
        final travel = Curves.easeOutCubic.transform(t);

        // 0 = still at the button; 1 = in its cell.
        return Transform.translate(
          offset: Offset(
            // Rightwards and downwards from the button: the panel is anchored
            // at the bottom-right, so everything in it comes from there.
            (1 - travel) * (28 + index % 4 * 6),
            (1 - travel) * (14 + index ~/ 4 * 10),
          ),
          child: Transform.scale(
            scale: 0.4 + 0.6 * eased,
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}

/// Grows a circle out of the panel's bottom-right corner.
///
/// `progress` runs 0→1 and the radius is measured to the far corner, so at 1
/// the circle contains the panel by construction rather than by a constant
/// somebody tuned on one phone.
class _ArcRevealClipper extends CustomClipper<Path> {
  _ArcRevealClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final centre = Offset(size.width, size.height);
    final reach = (size.width + size.height) * Curves.easeOutCubic.transform(
      progress.clamp(0.0, 1.0),
    );
    return Path()
      ..addOval(Rect.fromCircle(center: centre, radius: reach))
      ..close();
  }

  @override
  bool shouldReclip(_ArcRevealClipper old) => old.progress != progress;
}

/// One button on the bar.
///
/// Copy and Paste are drawn as ICONS while every other key is a word, and that
/// is deliberate rather than decorative: `Ctrl+C` in a terminal is SIGINT, not
/// copy. A bar that rendered a button reading "Copy" in the same style as a
/// button reading "C-c" would be inviting the one mistake that costs you a
/// running agent.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.cap,
    required this.armed,
    required this.enabled,
    required this.onTap,
    required this.palette,
  });

  final SoftKey cap;
  final bool armed;
  final bool enabled;
  final VoidCallback onTap;
  final TerminalColors palette;

  @override
  Widget build(BuildContext context) {
    // The chips are APP chrome that happens to float over the terminal, so
    // they take the app's chip colours — the same fill and edge as every other
    // control in the app. They used to be spelled out in hex, which was the
    // built-in palette written down a second time: a scheme changed the
    // terminal underneath while the bar stayed the old navy.
    final colors = HerdrTheme.of(context);
    final foreground = armed
        ? palette.cursor
        : cap.isAction
        // The one interactive tint. Not a status colour: Copy and Paste are
        // controls, and borrowing "working" to mean "button" is how a colour
        // stops meaning anything.
        ? colors.accent
        : colors.textDim;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      // `Align` WITH A WIDTH FACTOR, not `Center`. A bare `Center` expands to
      // fill whatever it is given, which is invisible in the bar (a horizontal
      // list gives it unbounded width, so it shrink-wraps anyway) and wrong the
      // moment the same cap is placed in the expanded panel: a `Wrap` hands its
      // children the FULL width as a loose constraint, so every cap became a
      // full-width pill and the panel turned into one key per row. `widthFactor`
      // asks for the child's own width; the bar's tight height still wins.
      child: Align(
        widthFactor: 1,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            height: 28,
            // NO `alignment`, and it is the whole reason the expanded panel
            // works: a `Container.alignment` wraps the child in an `Align` with
            // NO width factor, which fills whatever width it is offered. In the
            // bar that is invisible (the list offers unbounded width), and in
            // the panel it made every cap a full-width pill — one key per row,
            // a 856-point-tall wall of chips. The chip must be the size of its
            // own label.
            decoration: BoxDecoration(
              color: armed
                  ? palette.cursor.withValues(alpha: 0.22)
                  : colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(
                color: armed ? palette.cursor : colors.hairline,
              ),
            ),
            // `Align` WITH A WIDTH FACTOR, for the vertical half of the job the
            // fixed `height` above hands over. A tight height makes the child
            // exactly 28 tall, and a `Text` given a tight height LAYS ITSELF
            // OUT AT THE TOP of it — the labels sat visibly high in their
            // pills, `esc` and `Ctrl` alike.
            //
            // Same rule as the outer `Align`, same reason: no `widthFactor`
            // means the box fills whatever width it is offered. In the bar
            // (unbounded) that is invisible; in the expanded panel (`Wrap`,
            // loose full-width constraints) it is a key per row.
            child: Align(
              widthFactor: 1,
              child: _label(foreground),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(Color foreground) => switch (cap) {
    SoftKey.copy => Icon(
      CupertinoIcons.doc_on_doc,
      size: 15,
      color: foreground,
    ),
    SoftKey.paste => Icon(
      CupertinoIcons.doc_on_clipboard,
      size: 15,
      color: foreground,
    ),
    _ => Text(
      cap.label,
      style: TextStyle(
        color: foreground,
        fontSize: TextSize.meta,
        fontFamily: HerdrFonts.mono,
      ),
    ),
  };
}
