import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/workspace/pane_actions.dart';
import 'package:herdr_pocket/domain/workspace/pane_info.dart';

/// Which rows a pane's action sheet offers.
///
/// This rule used to be written twice — once behind the long press on the
/// workspaces list and once in the terminal's overflow sheet — and the failure
/// mode of writing it twice is silent: one screen offers "Git changes" and the
/// other does not, and nothing about either screen looks wrong. So the rule
/// lives in one function and is checked here.
PaneInfo pane({String? cwd, bool focused = false, String agent = ''}) =>
    PaneInfo(
      paneId: 'w9:p1',
      workspaceId: 'w9',
      tabId: 'w9:t1',
      cwd: cwd,
      agent: agent,
      isFocused: focused,
    );

void main() {
  test('the ledger row is offered only for an agent we can read', () {
    // Two gates in one: the agent has to be one of the adapters this build
    // ships, and the beta switch has to have been turned on — which is what
    // passing an empty list means.
    final withBeta = paneActionsFor(
      pane(cwd: '/x', agent: 'pi'),
      ledgerAgents: const ['pi', 'codex'],
    );
    expect(withBeta, contains(PaneAction.ledger));

    final withoutBeta = paneActionsFor(pane(cwd: '/x', agent: 'pi'));
    expect(withoutBeta, isNot(contains(PaneAction.ledger)));

    final otherAgent = paneActionsFor(
      pane(cwd: '/x', agent: 'claude'),
      ledgerAgents: const ['pi', 'codex'],
    );
    expect(otherAgent, isNot(contains(PaneAction.ledger)));
  });

  test('an agent name is matched without regard to case or padding', () {
    final actions = paneActionsFor(
      pane(cwd: '/x', agent: ' Pi '),
      ledgerAgents: const ['pi'],
    );
    expect(actions, contains(PaneAction.ledger));
  });

  test('a pane with no directory offers no ledger either', () {
    // There is nothing to find the session file by, which is the same reason
    // files and git are not offered.
    final actions = paneActionsFor(
      pane(agent: 'pi'),
      ledgerAgents: const ['pi'],
    );
    expect(actions, isNot(contains(PaneAction.ledger)));
  });

  test('a pane with a directory offers files and git', () {
    final actions = paneActionsFor(pane(cwd: '/x'));
    expect(actions, [
      PaneAction.browseFiles,
      PaneAction.git,
      // Every one of these panes is unfocused in this fixture.
      PaneAction.focus,
    ]);
  });

  test('a pane with no directory offers neither files nor git', () {
    // The daemon reports `cwd` as optional and a pane whose shell has exited
    // genuinely has none. Opening the file browser there would show a page
    // whose only honest content is "no directory", so the row is not drawn.
    final actions = paneActionsFor(pane());
    expect(actions, isNot(contains(PaneAction.browseFiles)));
    expect(actions, isNot(contains(PaneAction.git)));
  });

  test('a blank directory counts as none', () {
    expect(
      paneActionsFor(pane(cwd: '   ')),
      isNot(contains(PaneAction.browseFiles)),
    );
  });

  test('a focused pane does not offer to focus itself', () {
    expect(
      paneActionsFor(pane(cwd: '/x', focused: true)),
      isNot(contains(PaneAction.focus)),
    );
  });

  test('open is only offered where the pane is not already open', () {
    // The terminal page IS the pane opened; a row that reopened it would only
    // close the screen offering it. The workspaces list passes `withOpen`.
    expect(paneActionsFor(pane(cwd: '/x')), isNot(contains(PaneAction.open)));
    expect(
      paneActionsFor(pane(cwd: '/x'), withOpen: true).first,
      PaneAction.open,
    );
  });

  test('a pane with nothing to offer returns an empty list, not a stub', () {
    // A focused pane with no directory: the sheet then shows only Cancel, and
    // that is the honest answer rather than a row that does nothing.
    expect(paneActionsFor(pane(focused: true)), isEmpty);
  });
}
