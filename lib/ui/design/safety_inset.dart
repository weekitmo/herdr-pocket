import 'package:flutter/widgets.dart';
import 'package:herdr_pocket/app/settings.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// The margin the app keeps clear of the system's edge gestures.
///
/// WHY A MARGIN AT ALL, WHEN THE PLATFORM ALREADY REPORTS AN INSET. The inset
/// tells you where the system's swipe band IS; it does not tell you how close a
/// finger can get to it without becoming part of it. A control whose edge
/// touches the band is a control the user will sometimes hit while trying to
/// swipe, and — the worse direction — a swipe that starts one millimetre into
/// the band never reaches the app at all. So the app sits the inset PLUS this
/// much clear of the edge, which is roughly a fingertip's worth of "no, not
/// you".
///
/// ONE [Space] STEP, on the app's own spacing scale: a margin that is not on
/// the scale is a number somebody picked by eye on one phone.
const double kSafetyInset = Space.lg;

/// Whether the platform reports a bottom edge that its own gestures own.
///
/// `systemGestureInsets` is the right signal and Flutter says so in as many
/// words: "simple press-drag-release swipe gestures which begin within the area
/// defined by systemGestureInsets may not [be delivered to the app]". It is
/// non-zero only on Android Q+ with gesture navigation, and stays zero on
/// three-button navigation — where there is no swipe band, and therefore
/// nothing to keep clear of.
bool platformOwnsBottomEdge(BuildContext context) =>
    MediaQuery.systemGestureInsetsOf(context).bottom > 0;

/// The extra margin to apply, given the user's choice and what the platform
/// reports.
///
/// Returns an [EdgeInsets] rather than a double so it can be ADDED to a
/// [MediaQueryData]'s padding in one expression, and so a future top or side
/// margin needs no change at the call sites.
EdgeInsets safetyInsetFor(BuildContext context, SafetyInsetMode mode) {
  final keep = shouldKeepSafetyInset(
    mode,
    systemGestures: platformOwnsBottomEdge(context),
  );
  return keep ? const EdgeInsets.only(bottom: kSafetyInset) : EdgeInsets.zero;
}

/// How much room the app must leave at the bottom before drawing anything that
/// can be touched.
///
/// READ THIS INSTEAD OF `MediaQuery.paddingOf(context).bottom` in the chrome
/// that sizes itself from the window edge, because the app root has already
/// folded the safety margin into that value. It is the system's inset plus the
/// user's margin, which is exactly what a floating dock has to clear.
double bottomChromeInset(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom;
