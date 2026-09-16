/// The chrome bar: one row, a title, and buttons with no chrome of their own.
///
/// WHAT THIS IS. A pinned 44-point row — the way back on the left, the page's
/// name in the middle, the page's actions on the right — over a page that
/// scrolls UNDERNEATH it. Nothing paints a background: no bar colour, no blur,
/// no band.
///
/// WHY THE TITLE IS IN THE ROW AND NOT ABOVE IT. A large title costs about
/// forty points of every screen before the first row of content, on a device
/// whose whole height is 640 — and it animates into the bar as you scroll
/// anyway, so the value it adds is one glance at the top. The bar says what the
/// page is, and the page shows what the page has. The pull-to-refresh readout
/// also lands directly under the bar, which is where a phone user looks for it,
/// rather than under a title that is about to scroll away.
///
/// WHY THE ACTION ICONS ARE BARE. They were circles for one revision: a filled
/// chip is what keeps a glyph legible over whatever scrolls past. The verdict
/// from the device was that four chips across the top of a terminal reads as a
/// toolbar of buttons rather than as chrome, and the board's two chips read as
/// stickers. The way back keeps its circle — it is the one control whose SHAPE
/// carries meaning, because it is the shape the whole platform gives it, and it
/// is the one the reference client draws that way.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Height of the button row, below the status bar.
///
/// 44 is the iOS navigation bar's own constant (`kMinInteractiveDimensionCupertino`),
/// and it is the number the pages were already laid out against, so switching to
/// this bar moves nothing.
const double kTopBarHeight = 44;

/// Diameter of the circle behind the way back.
///
/// 36 leaves the standard 4-point gap above and below inside a 44-point row and
/// is comfortable under a thumb — the terminal's overflow button already
/// documented 36 as its own target size before this component existed.
const double kTopBarButtonSize = 36;

/// Horizontal margin of the leading and trailing buttons.
const double kTopBarEdge = Space.lg;

/// How far a page must have scrolled before the bar's title is considered gone.
///
/// A few points rather than one: a list that has barely moved should not blink
/// its title away, and a rubber-band overscroll at the top settles back to zero
/// inside this margin.
const double _kTitleFadeSlack = 4;

/// One chrome action: a glyph, with a target the size of a fingertip.
///
/// [circled] wraps it in a filled circle, and only the way back asks for it.
class HerdrBarButton extends StatelessWidget {
  const HerdrBarButton({
    required this.child,
    this.onPressed,
    this.identifier,
    this.label,
    this.ink,
    this.circled = false,
    super.key,
  });

  /// The glyph. Rendered inside an [IconTheme], so an [Icon] that does not name
  /// a colour picks up the button's ink.
  final Widget child;

  /// Null disables the button: it stops accepting taps and its glyph dims,
  /// which is the whole visual difference between "nothing is running" and
  /// "this is broken".
  final VoidCallback? onPressed;

  /// Android `resource-id` for the device checks, via `Semantics(identifier:)`.
  ///
  /// Optional because not every button is driven by a script, but when it IS
  /// given it has to be unique on screen — `test/ui/semantics_contract_test.dart`
  /// is what keeps that honest.
  final String? identifier;

  /// What a screen reader reads. Defaults to the child's own semantics.
  final String? label;

  /// Overrides the glyph's colour. Defaults to the app's interactive colour,
  /// which is what every chrome action already used — the terminal overrides it,
  /// because a button over a terminal grid is not over the app's ground.
  final Color? ink;

  /// Draws a filled circle behind the glyph.
  final bool circled;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final enabled = onPressed != null;
    final glyphColor = ink ?? (enabled ? colors.accent : colors.textFaint);

    final Widget glyph = SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: circled
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                  // The lift comes from the app's one elevation recipe, which
                  // already knows that light mode needs a shadow and dark mode
                  // does not.
                  boxShadow: Elevation.card(colors),
                ),
                child: SizedBox(
                  width: kTopBarButtonSize,
                  height: kTopBarButtonSize,
                  child: Center(child: child),
                ),
              )
            : child,
      ),
    );

    final button = CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: 0.6,
      onPressed: onPressed,
      child: IconTheme(
        data: IconThemeData(color: glyphColor, size: 22),
        child: glyph,
      ),
    );

    if (identifier == null) return button;
    return Semantics(
      identifier: identifier,
      button: true,
      enabled: enabled,
      label: label,
      // THE ACTION HAS TO BE ON THIS NODE. A `Semantics` wrapper around a
      // `CupertinoButton` otherwise produces a labelled node that cannot be
      // activated — the identifier introduces a node, the button keeps its own,
      // and the tap stays with the child. `excludeSemantics` drops the child's
      // node so this one IS the button.
      onTap: onPressed,
      excludeSemantics: true,
      child: button,
    );
  }
}

/// The way back: a chevron in a circle.
///
/// The circle is not decoration — it is the shape the platform gives this
/// control, and the only one in the chrome that carries meaning by itself.
class HerdrBackButton extends StatelessWidget {
  const HerdrBackButton({
    required this.label,
    this.onPressed,
    this.identifier,
    super.key,
  });

  /// Read aloud, and the only thing a screen reader has to go on: a chevron is
  /// not a word.
  final String label;

  /// Defaults to popping the route. Given explicitly by pages that would rather
  /// leave some other way.
  final VoidCallback? onPressed;

  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    return HerdrBarButton(
      identifier: identifier,
      label: label,
      circled: true,
      // Ink rather than the interactive accent: this glyph sits on a surface of
      // its own, and a control with a surface is drawn in ink everywhere else in
      // this app — the same rule the filled primary button follows.
      ink: colors.text,
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
      child: const Icon(CupertinoIcons.back, size: 20),
    );
  }
}

/// The bar as a plain widget, for pages whose body does not scroll.
///
/// Implements [ObstructingPreferredSizeWidget] so it can be dropped into
/// `CupertinoPageScaffold.navigationBar`: the scaffold stacks it over the body
/// either way, and [obstructs] decides whether the body is pushed down or is
/// merely told about the bar through `MediaQuery.padding`.
///
/// [obstructs] is TRUE by default — a fixed body (the terminal grid, a form)
/// must not be drawn under the buttons. Pages that scroll pass false so their
/// scroll view keeps the full height and insets its own content: that is what
/// lets a list run underneath the bar instead of stopping at it.
class HerdrTopBar extends StatefulWidget
    implements ObstructingPreferredSizeWidget {
  const HerdrTopBar({
    this.leading,
    this.actions = const <Widget>[],
    this.title,
    this.obstructs = true,
    super.key,
  });

  final Widget? leading;
  final List<Widget> actions;

  /// Shown inline between the two groups.
  ///
  /// It FADES OUT once the body below has been scrolled: the bar is transparent,
  /// so a title that stayed would end up printed over the rows moving past it.
  /// The offset comes from the page scaffold's own `ScrollNotificationObserver`,
  /// which is the mechanism `CupertinoNavigationBar` uses for the same question
  /// — no controller has to be threaded from the page into the bar.
  final Widget? title;

  final bool obstructs;

  @override
  Size get preferredSize => const Size.fromHeight(kTopBarHeight);

  @override
  bool shouldFullyObstruct(BuildContext context) => obstructs;

  @override
  State<HerdrTopBar> createState() => _HerdrTopBarState();
}

class _HerdrTopBarState extends State<HerdrTopBar> {
  /// How far the body must have moved before the title is considered gone.
  ///
  /// A few points rather than one: a list that has barely moved should not blink
  /// its title away, and a rubber-band overscroll at the top settles back to
  /// zero here.
  static const double _slack = 4;

  ScrollNotificationObserverState? _observer;
  bool _scrolledUnder = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (observer == _observer) return;
    _observer?.removeListener(_onScroll);
    _observer = observer;
    _observer?.addListener(_onScroll);
  }

  @override
  void dispose() {
    _observer?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll(ScrollNotification notification) {
    // Only the page's OWN scroll view: a nested horizontal scroller (a key bar,
    // a wide table) reports at depth > 0 and says nothing about the page.
    if (notification.depth != 0) return;
    if (notification.metrics.axis != Axis.vertical) return;
    final scrolled = notification.metrics.pixels > _slack;
    if (scrolled == _scrolledUnder) return;
    setState(() => _scrolledUnder = scrolled);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    return _BarRow(
      leading: widget.leading,
      actions: widget.actions,
      title: title == null
          ? null
          : _FadingTitle(visible: !_scrolledUnder, child: title),
      // The bar paints over the status bar strip and pushes its own row below
      // it — the same thing CupertinoNavigationBar does, and the reason its
      // preferredSize can stay 44 while it visibly occupies more.
      topInset: MediaQuery.paddingOf(context).top,
      height: kTopBarHeight,
    );
  }
}

/// The bar as a pinned sliver, for pages built out of slivers.
///
/// The same row, pinned over a `CustomScrollView` so the content scrolls under
/// it. `SliverPersistentHeader` is Flutter's own machinery for this — the same
/// thing `CupertinoSliverNavigationBar` and Material's `SliverAppBar` are built
/// on — and what it gives that a plain widget cannot is `overlapsContent`:
/// whether anything has scrolled under the bar, which is the signal the title
/// fades on.
class HerdrSliverTopBar extends StatelessWidget {
  const HerdrSliverTopBar({
    this.leading,
    this.actions = const <Widget>[],
    this.title,
    super.key,
  });

  final Widget? leading;
  final List<Widget> actions;

  /// The page's own name. It sits in the row, between the two groups.
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);

    // Built HERE, once per page build, in the page's own context — not inside
    // the delegate, which the sliver rebuilds during layout.
    final titleWidget = title == null
        ? null
        : Text(
            title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.text, fontSize: TextSize.title),
          );

    return SliverPersistentHeader(
      pinned: true,
      delegate: _TopBarDelegate(
        topInset: MediaQuery.paddingOf(context).top,
        leading: leading,
        actions: actions,
        title: titleWidget,
      ),
    );
  }
}

class _TopBarDelegate extends SliverPersistentHeaderDelegate {
  _TopBarDelegate({
    required this.topInset,
    required this.leading,
    required this.actions,
    required this.title,
  });

  final double topInset;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? title;

  @override
  double get minExtent => topInset + kTopBarHeight;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final titleWidget = title;
    // `shrinkOffset`, NOT `overlapsContent`, and the difference cost a round
    // trip to the device: `overlapsContent` reports whether the sliver BEFORE
    // this one is painting over it, which for the first sliver on a page is
    // never (measured: the title stayed at full brightness — #ECEFF4 — after a
    // 500-point scroll). For a pinned header `shrinkOffset` is how far the
    // viewport has moved past its leading edge, which is exactly the question.
    final scrolled = shrinkOffset > _kTitleFadeSlack;
    return _BarRow(
      leading: leading,
      actions: actions,
      title: titleWidget == null
          ? null
          : _FadingTitle(visible: !scrolled, child: titleWidget),
      topInset: topInset,
      height: kTopBarHeight,
    );
  }

  @override
  bool shouldRebuild(_TopBarDelegate old) {
    return old.topInset != topInset ||
        old.title != title ||
        !identical(old.leading, leading) ||
        !_sameActions(old.actions, actions);
  }

  static bool _sameActions(List<Widget> a, List<Widget> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

/// The title, or nothing, depending on whether the page has scrolled.
///
/// Cross-faded rather than cut: the bar has no background, so the title passes
/// over the content on its way out and a hard switch would read as a flicker.
class _FadingTitle extends StatelessWidget {
  const _FadingTitle({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: Motion.standard,
      child: child,
    );
  }
}

/// The row itself: leading on the left, actions on the right, the title
/// centred on the screen.
///
/// A CUSTOM LAYOUT RATHER THAN A ROW, for one reason: a `Row` centres the title
/// in whatever space is LEFT, so the title of a page whose two groups are
/// different widths sits off-centre — on the terminal, with four actions against
/// one way back, it drifts most of a third of the screen to the left. iOS
/// centres a navigation title on the SCREEN, and clipping it to the gap between
/// the two groups is the price: a title that ran under the buttons would be
/// worse than a short one.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.leading,
    required this.title,
    required this.actions,
    required this.topInset,
    required this.height,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final double topInset;
  final double height;

  @override
  Widget build(BuildContext context) {
    final leading = this.leading;
    final title = this.title;
    return SizedBox(
      height: topInset + height,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: CustomMultiChildLayout(
          delegate: _BarLayout(hasTitle: title != null),
          children: <Widget>[
            if (leading != null)
              LayoutId(id: _BarSlot.leading, child: leading),
            if (title != null) LayoutId(id: _BarSlot.title, child: title),
            if (actions.isNotEmpty)
              LayoutId(
                id: _BarSlot.actions,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (var i = 0; i < actions.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: Space.sm),
                      actions[i],
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _BarSlot { leading, title, actions }

class _BarLayout extends MultiChildLayoutDelegate {
  _BarLayout({required this.hasTitle});

  final bool hasTitle;

  @override
  void performLayout(Size size) {
    final leading = hasChild(_BarSlot.leading)
        ? layoutChild(_BarSlot.leading, BoxConstraints.loose(size))
        : Size.zero;
    final actions = hasChild(_BarSlot.actions)
        ? layoutChild(_BarSlot.actions, BoxConstraints.loose(size))
        : Size.zero;

    final leadingEnd = hasChild(_BarSlot.leading)
        ? kTopBarEdge + leading.width
        : kTopBarEdge;
    final actionsStart = hasChild(_BarSlot.actions)
        ? size.width - kTopBarEdge - actions.width
        : size.width - kTopBarEdge;

    if (hasChild(_BarSlot.leading)) {
      positionChild(
        _BarSlot.leading,
        Offset(kTopBarEdge, (size.height - leading.height) / 2),
      );
    }
    if (hasChild(_BarSlot.actions)) {
      positionChild(
        _BarSlot.actions,
        Offset(actionsStart, (size.height - actions.height) / 2),
      );
    }
    if (!hasTitle) return;

    // The gap between the two groups: the title may never be wider than this,
    // whatever else happens.
    final gap = math.max<double>(0, actionsStart - leadingEnd - Space.sm * 2);
    final title = layoutChild(
      _BarSlot.title,
      BoxConstraints(maxWidth: gap, maxHeight: size.height),
    );

    // CENTRED WHEN IT FITS, BESIDE THE LEADING WHEN IT DOES NOT.
    //
    // Centring on the screen is what iOS does and what makes a short title look
    // like a navigation title rather than a label in a box. But centring only
    // works when the two groups are about the same width: with four actions
    // against one way back — the terminal — the screen-centred slot is narrower
    // than the gap, and a title that insisted on being centred would be ellipsed
    // to nothing while a hundred points of room sat unused next to it.
    final centredLimit = math.max<double>(
      0,
      math.min(size.width / 2 - leadingEnd, actionsStart - size.width / 2) -
          Space.sm,
    ) * 2;
    final centred = title.width <= centredLimit;
    final left = centred
        ? (size.width - title.width) / 2
        : leadingEnd + Space.sm;
    positionChild(
      _BarSlot.title,
      Offset(left, (size.height - title.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_BarLayout old) => old.hasTitle != hasTitle;
}
