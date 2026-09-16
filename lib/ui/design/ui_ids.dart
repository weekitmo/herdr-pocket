/// Stable hooks for the automated UI checks.
///
/// WHY THIS EXISTS. `adb shell uiautomator dump` can read Flutter's semantics
/// tree, which is how `tool/device_check.sh` drives the app without guessing
/// coordinates. But a dump can only be addressed by what the tree exposes, and
/// LABELS ARE A POOR ADDRESS:
///
///   * they are translated, so a check written in one locale is a check that
///     breaks in the other;
///   * they change with state — the safety row reads 默认, 强制开启 or 强制关闭;
///   * and two nodes can legitimately carry the same words. The moment 强制开启
///     is the current value, the ROW and the MENU ITEM both say it, and the
///     device check's second tap had two candidates. A `contains` match then
///     taps whichever comes first in the tree, which is a coin flip that passes
///     often enough to look fine.
///
/// `Semantics(identifier:)` is the fix, and it is the documented one: on Android
/// it becomes `AccessibilityNodeInfo.setViewIdResourceName` — the `resource-id`
/// of the accessibility node — so a check can say "tap `safety-margin`" and mean
/// exactly one control, in any locale, in any state.
///
/// WHEN TO ADD ONE. A control that a check has to reach, or that every check has
/// to pass through to get anywhere (the dock). NOT every widget: an identifier
/// on everything is a second name for everything, and it helps nobody while
/// making the tree harder to read.
///
/// THE RULE THAT KEEPS IT HONEST: a screen must not have two nodes with the same
/// identifier, which is asserted in `test/ui/semantics_contract_test.dart` — so
/// adding one here without wiring it up fails a test rather than silently doing
/// nothing.
abstract final class UiId {
  /// The floating dock's three destinations.
  ///
  /// Every device check starts by navigating, so these are the ids with the
  /// widest reach.
  static const dockBoard = 'dock-board';
  static const dockWorkspaces = 'dock-workspaces';
  static const dockSettings = 'dock-settings';

  /// The board's two navbar entries.
  static const openMachines = 'open-machines';
  static const openJump = 'open-jump';

  /// The machines screen.
  static const addMachine = 'add-machine';

  // --- 安全边界 -------------------------------------------------------------
  //
  // A row whose value is one of three words, and a menu whose rows are those
  // same three words: the exact shape that made label addressing ambiguous.
  static const safetyMargin = 'safety-margin';
  static const safetyDefault = 'safety-default';
  static const safetyAlwaysOn = 'safety-always-on';
  static const safetyAlwaysOff = 'safety-always-off';
}
