import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/app/frame_phase.dart';

/// `runOutsideFrame` — the guard that keeps a mid-frame write from freezing the
/// whole app. See `lib/app/frame_phase.dart` for the mechanism; what is pinned
/// here is the contract: from idle it runs NOW (no added latency for the common
/// case, which is every button press), and from inside a frame it runs at the
/// end of that same frame and still reaches the screen.
void main() {
  testWidgets('a write from idle happens in the same turn', (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(
      SchedulerBinding.instance.schedulerPhase,
      SchedulerPhase.idle,
      reason: 'between frames is the case every button press lands in',
    );

    var ran = false;
    runOutsideFrame(() => ran = true);

    expect(
      ran,
      isTrue,
      reason: 'deferring when nothing is being drawn would delay every '
          'ordinary write by a frame for no reason',
    );
  });

  testWidgets('a write made from inside a frame is deferred, and still lands', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    var ran = false;
    var phaseWhenRun = SchedulerPhase.idle;
    // A persistent frame callback IS the phase `State.dispose` runs in: see
    // `WidgetsBinding.drawFrame`, which calls `buildScope` and then
    // `finalizeTree` (the unmount pass) inside this same callback.
    _onceInsideAFrame(() {
      runOutsideFrame(() {
        ran = true;
        phaseWhenRun = SchedulerBinding.instance.schedulerPhase;
      });
      expect(
        ran,
        isFalse,
        reason: 'writing here leaves the build owner convinced a frame is '
            'already on its way, and after that nothing schedules one again',
      );
    });

    await tester.pump();

    expect(ran, isTrue, reason: 'a deferred write cannot be lost');
    expect(
      phaseWhenRun,
      SchedulerPhase.postFrameCallbacks,
      reason: 'the post-frame phase is one of the two where asking for a frame '
          'still works',
    );
  });

  testWidgets('what a deferred write changes is on screen a frame later', (
    tester,
  ) async {
    final value = ValueNotifier<String>('before');
    addTearDown(value.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<String>(
        valueListenable: value,
        builder: (_, text, _) => Text(text, textDirection: TextDirection.ltr),
      ),
    );

    _onceInsideAFrame(() => runOutsideFrame(() => value.value = 'after'));

    await tester.pump();
    expect(
      find.text('before'),
      findsOneWidget,
      reason: 'the write happened after the frame that could have drawn it',
    );

    await tester.pump();
    expect(
      find.text('after'),
      findsOneWidget,
      reason: 'and the frame the deferred write asked for arrived, which is '
          'the whole point of deferring rather than dropping it',
    );
  });
}

/// Runs [body] inside the next frame's persistent-callback phase, exactly once.
///
/// One-shot because the binding keeps persistent frame callbacks for the whole
/// test FILE: a callback that stays armed would fire again during a later
/// test's warm-up frame and make the next failure unreadable.
void _onceInsideAFrame(VoidCallback body) {
  var done = false;
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (done) return;
    done = true;
    expect(
      SchedulerBinding.instance.schedulerPhase,
      SchedulerPhase.persistentCallbacks,
      reason: 'this test is only meaningful from inside the frame',
    );
    body();
  });
  // The test binding draws a frame only when one is scheduled.
  SchedulerBinding.instance.scheduleFrame();
}
