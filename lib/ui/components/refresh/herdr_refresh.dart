import 'dart:math' as math;

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/domain/refresh/refresh_style.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// How far the page has to be pulled before a refresh arms.
///
/// ONE VALUE FOR ALL THREE STYLES, and that is a constraint rather than tidiness:
/// the threshold is a property of the EasyRefresh header, which is configured
/// once and cannot be re-configured mid-gesture. Three styles with three
/// thresholds would mean three headers, and therefore deciding the style before
/// the pull starts — which is the thing this design exists to avoid.
const double kHerdrRefreshTriggerOffset = 110;

/// The shortest time a refresh animation is shown, however fast the read was.
///
/// THE ANIMATIONS ARE THE FEATURE, so a refresh that completes in 40ms — which
/// is what a read over a local network does — would show a flicker and nothing
/// else. Half a second is long enough to see which of the three played and
/// short enough not to be felt as waiting; the DATA is not delayed at all, only
/// the closing of the panel.
const Duration kHerdrRefreshMinimumVisible = Duration(milliseconds: 500);

/// Runs [work] and keeps the refresh animation up for the minimum.
///
/// `Future.wait` rather than `await work(); await delay();` because the two are
/// independent: the indicator's clock starts when the gesture does, and a slow
/// read must not get another half second added on top of it.
Future<void> withRefreshAnimation(Future<void> Function() work) =>
    Future.wait<void>([work(), Future<void>.delayed(kHerdrRefreshMinimumVisible)]);

/// The pull-to-refresh header, with a different animation each time.
///
/// WHY A DECK AND NOT A RANDOM PICK: see [RefreshStyleDeck]. This file is the
/// wiring; the rule lives in the domain where it is testable.
///
/// WHY THESE THREE. They are the three named demos of the easy_refresh example
/// — "冲上云霄", "太空轨道", "气球快递" — and two of them (Taurus, Delivery) are
/// the package's own widgets, called through their public `build`. The third
/// (Space) is a Rive animation in a separate package whose runtime is a native
/// library; it is redrawn here with the same idea — a body orbiting a star,
/// with the pull angle driving it — because a native animation runtime is a
/// large price for one refresh animation in an app built for a 2018 phone.
class HerdrRefreshHeader extends Header {
  HerdrRefreshHeader({required this.deck})
      : super(
          triggerOffset: kHerdrRefreshTriggerOffset,
          // Not clamped: the indicator IS the overscroll area, so clamping
          // would freeze the pull the moment it became interesting.
          clamping: false,
          position: IndicatorPosition.locator,
          safeArea: false,
        );

  /// Hands out one style per pull.
  final RefreshStyleDeck deck;

  @override
  Widget build(BuildContext context, IndicatorState state) =>
      _RotatingIndicator(deck: deck, state: state);
}

/// Plays the style the deck handed out, and picks the next one at the START of
/// the next pull.
class _RotatingIndicator extends StatefulWidget {
  const _RotatingIndicator({required this.deck, required this.state});

  final RefreshStyleDeck deck;
  final IndicatorState state;

  @override
  State<_RotatingIndicator> createState() => _RotatingIndicatorState();
}

class _RotatingIndicatorState extends State<_RotatingIndicator> {
  /// Null until the pull begins, so nothing is drawn at rest.
  RefreshStyle? _style;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pulling = state.mode != IndicatorMode.inactive &&
        state.mode != IndicatorMode.done;

    // CHOSEN HERE, IN BUILD, AND ONLY ONCE PER PULL. The framework rebuilds
    // this widget on every pixel of the gesture, so `??=` is what makes it
    // "once": the second call of the same pull finds a style and keeps it.
    //
    // The alternative — a mode-change listener with `setState` — picks at the
    // same moment and can fire while the scroll view is building, which is a
    // rebuild during build. This has no such window, and a wrong pick here
    // costs one entry of a three-entry deck.
    if (pulling) {
      _style ??= widget.deck.next();
    } else if (state.offset == 0) {
      _style = null;
    }

    final style = _style;
    if (style == null) return const SizedBox.shrink();

    // The sky is the app's own tint, not the demo's blue: the package defaults
    // to `colorScheme.primary` and takes a colour for exactly this reason. One
    // knob, one line, if it should be something else.
    final sky = HerdrTheme.of(context).accent;

    return switch (style) {
      RefreshStyle.soaring =>
        TaurusHeader(skyColor: sky).build(context, state),
      RefreshStyle.delivery =>
        DeliveryHeader(skyColor: sky).build(context, state),
      RefreshStyle.orbit => _OrbitHeader(skyColor: sky).build(context, state),
    };
  }
}

/// A body circling a star. "太空轨道".
///
/// The pull turns the orbit; once the refresh is running it keeps turning, which
/// is the loading indicator — the same division of labour the other two have
/// (the plane flies, the balloons bob) and why none of them needs a spinner on
/// top.
class _OrbitHeader extends Header {
  const _OrbitHeader({required this.skyColor})
      : super(
          triggerOffset: kHerdrRefreshTriggerOffset,
          clamping: false,
          position: IndicatorPosition.locator,
          safeArea: false,
        );

  final Color skyColor;

  @override
  Widget build(BuildContext context, IndicatorState state) =>
      _OrbitIndicator(state: state, skyColor: skyColor);
}

class _OrbitIndicator extends StatefulWidget {
  const _OrbitIndicator({required this.state, required this.skyColor});

  final IndicatorState state;
  final Color skyColor;

  @override
  State<_OrbitIndicator> createState() => _OrbitIndicatorState();
}

class _OrbitIndicatorState extends State<_OrbitIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    widget.state.notifier.addModeChangeListener(_onMode);
  }

  @override
  void dispose() {
    widget.state.notifier.removeModeChangeListener(_onMode);
    _spin.dispose();
    super.dispose();
  }

  void _onMode(IndicatorMode mode, double offset) {
    if (mode == IndicatorMode.processing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (mode == IndicatorMode.processed ||
        mode == IndicatorMode.inactive) {
      if (_spin.isAnimating) _spin.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HerdrTheme.of(context);
    final state = widget.state;
    final pull = (state.offset / state.actualTriggerOffset).clamp(0.0, 1.0);

    return SizedBox(
      height: state.offset,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(
          painter: _OrbitPainter(
            sky: widget.skyColor,
            // The pull positions the body; the spin carries it once the pull is
            // over, so the two never fight over the same number.
            turns: pull * 0.75 + _spin.value,
            pull: pull,
            ink: colors.text,
          ),
        ),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.sky,
    required this.turns,
    required this.pull,
    required this.ink,
  });

  final Color sky;
  final double turns;
  final double pull;
  final Color ink;

  /// Fixed star positions — a fixed constellation, so the band does not
  /// reshuffle itself every frame the way an unseeded random would.
  static const _stars = <Offset>[
    Offset(0.10, 0.30), Offset(0.22, 0.68), Offset(0.37, 0.22),
    Offset(0.52, 0.74), Offset(0.66, 0.34), Offset(0.78, 0.62),
    Offset(0.88, 0.26), Offset(0.94, 0.70), Offset(0.05, 0.80),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) return;
    final rect = Offset.zero & size;
    canvas.clipRect(rect);
    canvas.drawRect(rect, Paint()..color = sky);

    for (final star in _stars) {
      canvas.drawCircle(
        Offset(star.dx * size.width, star.dy * size.height),
        1.1,
        Paint()..color = ink.withValues(alpha: 0.35 + 0.4 * pull),
      );
    }

    // The orbit is a wide, flat ellipse — the angle a planet's track makes when
    // you look at it from the side of the solar system rather than from above.
    final centre = Offset(size.width / 2, size.height * 0.62);
    final radiusX = math.min(size.width * 0.3, 130);
    final radiusY = radiusX * 0.34;
    final orbit = Rect.fromCenter(
      center: centre,
      width: radiusX * 2,
      height: radiusY * 2,
    );
    canvas.drawOval(
      orbit,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ink.withValues(alpha: 0.22),
    );

    final angle = turns * 2 * math.pi;
    final body = Offset(
      centre.dx + radiusX * math.cos(angle),
      centre.dy + radiusY * math.sin(angle),
    );
    // THE STAR IS DRAWN TWICE, AND THE ORDER IS THE WHOLE TRICK. A body on a
    // flat ellipse that is always painted on top reads as a dot sliding along a
    // line; painting it BEHIND the star for the half of the orbit where it is
    // "far" from the viewer is what makes the track read as a track.
    // THE TWO BODIES HAVE TO LOOK LIKE TWO DIFFERENT THINGS. They were both
    // plain circles, which read as one white dot that teleported when the
    // planet passed the star. So: the star gets a halo and stays small, and the
    // planet gets a ring — a planet with a ring is not mistakable for a star at
    // any size this is drawn at.
    final behind = math.sin(angle) < 0;
    final bodyRadius = 5.0 + 2 * pull;
    final starRadius = 3.5 + 2 * pull;

    if (behind) canvas.drawCircle(body, bodyRadius, Paint()..color = ink);
    canvas.drawCircle(
      centre,
      starRadius * 2.1,
      Paint()..color = ink.withValues(alpha: 0.22),
    );
    canvas.drawCircle(centre, starRadius, Paint()..color = ink);

    final planet = Paint()..color = ink;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = behind ? ink.withValues(alpha: 0.55) : ink;
    canvas.drawCircle(body, bodyRadius, planet);
    canvas.drawOval(
      Rect.fromCenter(
        center: body,
        width: bodyRadius * 2.8,
        height: bodyRadius * 0.9,
      ),
      ring,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.turns != turns ||
      old.pull != pull ||
      old.sky != sky ||
      old.ink != ink;
}
