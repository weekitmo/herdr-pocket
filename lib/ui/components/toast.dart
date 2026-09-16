import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// A brief message over the current screen.
///
/// HAND-ROLLED because the obvious one is Material. `ScaffoldMessenger` and
/// `SnackBar` both come from `package:flutter/material.dart`, and this project's
/// no-Material rule is enforced by a test rather than by discipline — so a
/// convenience that quietly drags the whole Material widget set into the tree
/// is exactly the thing that rule exists to stop.
///
/// An [OverlayEntry] rather than a route: a toast must not participate in
/// navigation. A route would be dismissible with the back gesture and would
/// have to be popped before the user could leave the screen that raised it.
void showHerdrToast(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final colors = HerdrTheme.of(context);
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;

  late final OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: Space.lg,
      right: Space.lg,
      bottom: MediaQuery.paddingOf(context).bottom + 120,
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(Radii.uniform),
              border: Border.all(color: colors.hairline),
              boxShadow: Elevation.card(colors),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.lg,
                vertical: Space.sm + 2,
              ),
              child: Text(
                message,
                style: TextStyle(
                  color: isError ? colors.statusTextDied : colors.text,
                  fontSize: TextSize.body,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  overlay.insert(entry);
  Timer(const Duration(milliseconds: 1700), remove);
}
