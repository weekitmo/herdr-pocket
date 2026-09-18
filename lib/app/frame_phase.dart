import 'package:flutter/scheduler.dart';

/// Runs [write] at a moment when marking a widget dirty still asks for a frame.
///
/// ## The trap this exists for
///
/// A state write that rebuilds a widget (`ProviderScope` state, a
/// `ValueNotifier` a widget listens to, `setState`) works by calling
/// `Element.markNeedsBuild`, which goes to `BuildOwner.scheduleBuildFor`:
///
/// ```dart
/// if (!_scheduledFlushDirtyElements && onBuildScheduled != null) {
///   _scheduledFlushDirtyElements = true;   // ← set HERE
///   onBuildScheduled!();                   // → ensureVisualUpdate()
/// }
/// ```
///
/// and `SchedulerBinding.ensureVisualUpdate` **only asks for a frame from the
/// idle and post-frame phases**:
///
/// ```dart
/// case SchedulerPhase.transientCallbacks:
/// case SchedulerPhase.midFrameMicrotasks:
/// case SchedulerPhase.persistentCallbacks:
///   return;                                // ← no frame requested
/// ```
///
/// The flag is only cleared again by `BuildOwner.buildScope`, i.e. at the START
/// of the next frame — which is the frame nobody asked for. So ONE write made
/// while a frame is being drawn leaves `_scheduledFlushDirtyElements` stuck at
/// `true` for the rest of the process: every later `markNeedsBuild` adds its
/// element to the dirty list and **never schedules a frame**.
///
/// The app then looks frozen in a very specific way — taps are delivered, the
/// callbacks run, the state changes, `print` shows all of it, and the screen
/// never repaints again. Only something that schedules a frame by another route
/// (an animation's ticker, an explicit `scheduleFrame`) revives it. Release
/// builds have no assert to warn about it, and debug builds only warn when the
/// write goes through Riverpod.
///
/// ## Where the frame is drawn from
///
/// `WidgetsBinding.drawFrame` calls `buildScope` and then `finalizeTree`, both
/// inside the `persistentCallbacks` phase. `finalizeTree` is the **unmount**
/// pass, so `State.dispose` and everything it calls runs in the one phase where
/// a dirty widget cannot ask for a frame. That is exactly where this was found:
/// the SSH shell page releasing its keep-alive hold in `dispose`, which froze
/// the whole app the moment the page was closed.
///
/// ## What this does
///
/// Nothing at all from the safe phases (idle, post-frame — the overwhelmingly
/// common case, including every button press). From inside a frame it defers to
/// the end of that same frame, which the scheduler is already going to run:
/// `addPostFrameCallback` runs in the `postFrameCallbacks` phase, where
/// `ensureVisualUpdate` does schedule. The write is therefore late by at most
/// one frame — never lost, never early.
void runOutsideFrame(VoidCallback write) {
  switch (SchedulerBinding.instance.schedulerPhase) {
    case SchedulerPhase.idle:
    case SchedulerPhase.postFrameCallbacks:
      write();
    case SchedulerPhase.transientCallbacks:
    case SchedulerPhase.midFrameMicrotasks:
    case SchedulerPhase.persistentCallbacks:
      // The frame already being drawn will run its post-frame callbacks before
      // it ends, so this needs no frame of its own.
      SchedulerBinding.instance.addPostFrameCallback((_) => write());
  }
}
