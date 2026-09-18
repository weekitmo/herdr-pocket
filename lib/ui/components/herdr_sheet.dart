import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// A yes/no the sheet's own route consults when something tries to close it.
///
/// A MUTABLE HOLDER RATHER THAN A `ValueNotifier`, deliberately: nothing
/// rebuilds from it. All three dismissal paths — the barrier's tap, the system
/// back gesture, and a fling of the header — READ it at the instant the user
/// asks, so a listener list would be machinery that never rings. It also has no
/// ownership to get wrong: there is no `dispose` to forget, or to race against
/// a barrier that is still on screen during the exit transition.
///
/// One caller uses it today: the update sheet, which must not be closable while
/// an APK is downloading — closing it would leave a 46 MB transfer running with
/// nothing on screen to watch or stop.
class SheetDismissal {
  /// Whether a back gesture, a barrier tap or a header fling may close the
  /// sheet right now.
  bool allowed = true;
}

/// A sheet that rises from the bottom, in this app's own material.
///
/// ## Why this is not `showCupertinoModalPopup` or `CupertinoActionSheet`
///
/// Those two are the obvious way to get a bottom sheet, and both are the wrong
/// shape here. `CupertinoActionSheet` renders a fixed list of same-height rows
/// with its own typography — it cannot hold a scrollable form, and it brings
/// iOS's sizes into a screen built on this app's font ladder. And
/// `CupertinoModalPopup` positions its child at the bottom but supplies no
/// surface: every caller would redraw the same rounded panel, the same dim, and
/// the same transition, and the third copy would be the one that drifts.
///
/// So the surface, the dim, the curve and the barrier are defined once, here,
/// and callers supply only what is inside.
///
/// ## The transition
///
/// A slide up with [Curves.easeOutCubic] and a fade on the barrier. Not a
/// spring: this sheet holds a form, and an overshooting bounce on a panel with
/// text fields in it reads as the panel being unstable rather than as
/// playfulness.
Future<T?> showHerdrSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, ScrollController scroll) builder,
  required String title,
  Widget? action,
  SheetDismissal? dismissal,
}) {
  final colors = HerdrTheme.of(context);

  return Navigator.of(context).push<T>(
    _HerdrSheetRoute<T>(
      dismissal: dismissal,
      barrierColor: colors.groundDeep.withValues(alpha: 0.45),
      builder: (routeContext) => HerdrSheet(
        title: title,
        action: action,
        dismissal: dismissal,
        builder: builder,
      ),
    ),
  );
}

/// The sheet's route, with a barrier that can be switched off while it is open.
///
/// BOTH OVERRIDES ARE POLICIES, NOT STATE: `barrierDismissible` is asked at the
/// moment of the tap and `popDisposition` at the moment of the back gesture, so
/// a sheet can become undismissable (and dismissable again) with no rebuild and
/// no route juggling. `popDisposition` is what makes the back gesture and the
/// header fling honour the same answer as the barrier — they both go through
/// `Navigator.maybePop`, which asks the route.
class _HerdrSheetRoute<T> extends PageRouteBuilder<T> {
  _HerdrSheetRoute({
    required this.dismissal,
    required super.barrierColor,
    required WidgetBuilder builder,
  }) : super(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder: (_, animation, _, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        );

  /// The policy, or null for "always dismissable".
  final SheetDismissal? dismissal;

  @override
  bool get barrierDismissible => dismissal?.allowed ?? true;

  @override
  RoutePopDisposition get popDisposition => barrierDismissible
      ? super.popDisposition
      : RoutePopDisposition.doNotPop;
}

/// The sheet surface itself.
///
/// Exported separately so a caller that needs its own route — the pairing
/// screen has a live camera and its own lifecycle — can still get the same
/// panel rather than a second, slightly different one.
class HerdrSheet extends StatefulWidget {
  /// Holds the sheet.
  const HerdrSheet({
    required this.title,
    required this.builder,
    this.action,
    this.dismissal,
    super.key,
  });

  final String title;

  /// The rounded button in the header, usually 保存 or 完成.
  ///
  /// A widget rather than a callback so the caller decides whether it is
  /// enabled, what it says, and whether it is a button at all — the pairing
  /// sheet wants a 完成 that only appears once there is something to finish.
  final Widget? action;

  /// The dismissal policy, when the caller has one. See [SheetDismissal].
  final SheetDismissal? dismissal;

  final Widget Function(BuildContext context, ScrollController scroll) builder;

  @override
  State<HerdrSheet> createState() => _HerdrSheetState();
}

class _HerdrSheetState extends State<HerdrSheet> {
  final _scroll = ScrollController();

  /// How far the header has been dragged, for the dismiss gesture.
  double _dragOffset = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // Downward only. Dragging up on a sheet does nothing, and pretending
    // otherwise is how a gesture starts fighting the scroll view underneath.
    final next = _dragOffset + details.delta.dy;
    setState(() => _dragOffset = next < 0 ? 0 : next);
  }

  void _onDragEnd(DragEndDetails details) {
    // Dismiss past a quarter of the sheet, or on a decisive flick. Two
    // conditions because a slow drag and a fast flick are different intents
    // that both mean "close this".
    //
    // AND ONLY WHEN THE POLICY ALLOWS IT. `maybePop` refuses on its own (the
    // route answers `doNotPop`), but then the sheet would stay translated down
    // by the drag with nothing left to close it: the offset is put back here in
    // the same frame the gesture ends.
    final height = context.size?.height ?? 1;
    final flung = details.velocity.pixelsPerSecond.dy > 700;
    if ((_dragOffset > height / 4 || flung) &&
        (widget.dismissal?.allowed ?? true)) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _dragOffset = 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final screen = MediaQuery.sizeOf(context);

    // THE KEYBOARD PUSHES THE SHEET UP rather than being padded around.
    //
    // The first version added `viewInsets.bottom` as padding INSIDE the panel,
    // which lifts the content but leaves the panel's own bottom edge behind the
    // keyboard — so the sheet looks like it is sliding under the keyboard while
    // its content floats. Reserving the strip BELOW the panel instead means the
    // panel sits ON the keyboard, which is what "being pushed up" looks like.
    //
    // Nothing else acts on `viewInsets` here: this is a modal route, not a
    // `Scaffold`, so `resizeToAvoidBottomInset` does not exist to do it for us.
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // Measured against what is LEFT above the keyboard, so the sheet
              // never grows taller than the space it is being pushed into.
              maxHeight: (screen.height - insets.bottom) * 0.92 - insets.top,
            ),
            child: HerdrSheetSurface(
              colors: colors,
            // HUGS ITS CONTENT, up to the cap above. Forcing the full height
            // was the first attempt and it looked broken on the device: the
            // pairing tab is shorter than the manual one, so it rendered as a
            // tall panel with a third of a screen of empty surface under the
            // button — which reads as content that failed to load rather than
            // as a sheet.
            //
            // `loose` is what makes that work with a scrollable inside: the
            // body is handed a range and may be smaller than it, and the
            // `shrinkWrap` lists the callers pass give it a real height to
            // measure.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Header(
                    title: widget.title,
                    action: widget.action,
                    onDragUpdate: _onDragUpdate,
                    onDragEnd: _onDragEnd,
                  ),
                  // `loose` IS the default; it is written out because the
                  // layout above only works because of it — a tight fit would
                  // hand the body the full remaining height and the sheet would
                  // go back to filling the screen.
                  Flexible(
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: KeepFocusedFieldVisible(
                        child: widget.builder(context, _scroll),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps whatever is being typed into near the middle of the space that is left.
///
/// ## Why this is not free with a scrollable
///
/// A text field already asks its scrollable to make it visible when it takes
/// focus, and that is enough to stop it being hidden — but it scrolls the
/// MINIMUM distance, so the field ends up flush against the keyboard. On a
/// sheet pushed up by a keyboard, with four fields above it, that reads as the
/// form having collapsed rather than as the field having moved.
///
/// So the same request is repeated with `alignment: 0.5`, which asks for the
/// field in the middle instead of at the edge. It is done in a post-frame
/// callback because the focus change and the keyboard animation both land after
/// the frame that caused them, and asking before the new layout exists scrolls
/// to where the field USED to be.
class KeepFocusedFieldVisible extends StatefulWidget {
  /// Holds the subtree to watch.
  const KeepFocusedFieldVisible({required this.child, super.key});

  final Widget child;

  @override
  State<KeepFocusedFieldVisible> createState() => _KeepFocusedFieldVisibleState();
}

class _KeepFocusedFieldVisibleState extends State<KeepFocusedFieldVisible> {
  /// The context of the field that currently has focus, if it is one of ours.
  BuildContext? _focused;

  /// The keyboard height seen on the last build.
  double? _keyboard;

  /// Whether a re-centring is already queued for the next frame.
  bool _scheduled = false;

  /// Wraps without drawing anything.
  ///
  /// It listens to two things and lays nothing out — the child keeps whatever
  /// constraints it was going to get.
  @override
  Widget build(BuildContext context) {
    // AND TO THE KEYBOARD, which is the half that was missing. Centring on the
    // focus event alone runs while the keyboard is still closed: the field is
    // measured against a viewport that is about to shrink by the height of the
    // keyboard, so it ends up sitting near the new bottom edge instead of in
    // the middle — measured on the device, exactly that.
    //
    // A keyboard animation reports a new height on every frame, so this fires
    // many times; `_scheduled` coalesces them to one re-centring per frame and
    // each retargets the same animation to almost the same place.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboard != _keyboard) {
      _keyboard = keyboard;
      _schedule();
    }
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final target = FocusManager.instance.primaryFocus?.context;
    if (target == null) {
      return;
    }
    // Ours only. The machines list behind the sheet has no fields, but the
    // terminal and the settings screens do, and scrolling THEIR scrollables
    // from here would be a very confusing bug to chase.
    if (target.findAncestorWidgetOfExactType<KeepFocusedFieldVisible>() != widget) {
      return;
    }
    _focused = target;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final target = _focused;
      if (!mounted || target == null) return;
      // The sheet may have been dismissed between the change and this callback
      // — which happens whenever a field is focused and the sheet is then
      // closed from its own header button.
      if (!target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      ).ignore();
    });
  }
}

/// The panel itself: the rounded surface the content sits on.
///
/// PUBLIC, and that is not for decoration. `HerdrSheet` is the whole route —
/// an [Align] that fills the screen so the panel can be pinned to the bottom —
/// so measuring `find.byType(HerdrSheet)` measures the SCREEN. A test that did
/// that once asserted "the sheet sits at the bottom" against a widget that
/// always spans the full height, and passed for the wrong reason. Anything that
/// wants to talk about the panel's position or size has to be able to name the
/// panel.
class HerdrSheetSurface extends StatelessWidget {
  /// Holds the surface.
  const HerdrSheetSurface({
    required this.colors,
    required this.child,
    this.bottomInset = 0,
    super.key,
  });

  final HerdrColors colors;
  final Widget child;

  /// Room to leave under the content, so the keyboard does not cover it.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.uniform),
        ),
        // Light mode only, like every other raised surface in the app: the
        // recipe returns nothing on a dark ground, where the surface step is
        // already what separates the panel from the page.
        boxShadow: Elevation.card(colors),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: child,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.action,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final String title;
  final Widget? action;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return GestureDetector(
      // On the header only, and that is deliberate: the body below belongs to
      // whatever the caller put there, and a form's own drag gestures must not
      // be stolen by the sheet.
      onVerticalDragUpdate: onDragUpdate,
      onVerticalDragEnd: onDragEnd,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.md, Space.md),
        child: Row(
          children: [
            // The title is centred by being given the space the action does not
            // use, which keeps it centred even when the action is wider than a
            // glyph. A `Center` in the remaining space would shift it.
            const SizedBox(width: _headerActionMinWidth),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: TextSize.strong,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: _headerActionMinWidth,
              child: action == null
                  ? null
                  : Align(alignment: Alignment.centerRight, child: action),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reserved on BOTH sides of the title so it stays optically centred.
const double _headerActionMinWidth = 64;

/// The rounded button that lives in a sheet header.
///
/// A filled pill with a word in it, not an icon in a circle. In a sheet the
/// header is the only chrome there is, and a bare glyph there has to be guessed
/// at; the word is unambiguous and it is what the reference design uses.
class HerdrSheetAction extends StatelessWidget {
  /// Holds the button.
  const HerdrSheetAction({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;

  /// Null disables it, and the disabled look is a colour change rather than a
  /// missing button: a control that disappears the moment it becomes
  /// unavailable makes the header jump.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final enabled = onPressed != null;

    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
      borderRadius: BorderRadius.circular(Radii.uniform),
      minimumSize: Size.zero,
      color: enabled ? colors.accent : colors.surfaceRaised,
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: enabled ? colors.ground : colors.textFaint,
          fontSize: TextSize.note,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The floating round button a list screen uses for its one primary action.
///
/// Beside the thumb rather than in the top bar, because reaching the top-right
/// corner of a modern phone with one hand is the hardest place on the screen to
/// get to, and this is the action a user with no machines almost certainly
/// wants.
class HerdrFloatingButton extends StatelessWidget {
  /// Holds the button.
  const HerdrFloatingButton({
    required this.label,
    required this.onPressed,
    this.icon = CupertinoIcons.add,
    this.identifier,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData icon;

  /// Android `resource-id` for the device checks.
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    return Semantics(
      button: true,
      label: label,
      identifier: identifier,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colors.accent,
            shape: BoxShape.circle,
            // The same recipe the cards use. Without it a saturated circle on
            // a light ground looks pasted on rather than lifted off.
            boxShadow: Elevation.card(colors),
          ),
          child: Icon(icon, size: 26, color: colors.ground),
        ),
      ),
    );
  }
}
