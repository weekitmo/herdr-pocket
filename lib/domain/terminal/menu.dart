/// The two menus a composed message can open: `/` for skills, `@` for files.
///
/// ## Why the composer has to own this
///
/// In a real terminal, typing `/` into codex, grok or pi makes the TUI pop up
/// its own menu, and `@` makes it list the workspace's files. That works
/// because the TUI SEES EACH KEYSTROKE.
///
/// A composer sends one paste. The pane receives `…/skill-name` as pasted text
/// and never has a keystroke to react to, so **neither menu would ever appear**.
/// The helper that makes a paragraph cheap on a bad link therefore removes two
/// things people reach for constantly — unless the composer draws them itself,
/// which is what this file is the rulebook for.
///
/// ## The rules, and where they come from
///
/// They are the semantics of the harness's own web composer, re-derived rather
/// than copied: a trigger opens at the start of the draft, after whitespace, or
/// after punctuation — never in the middle of a word — and `/` is additionally
/// dead inside a URL, because `https://example.com/a/b` is a link and not a
/// command. `@` gets the same word rule, which is what keeps `someone@host` an
/// address.
///
/// PURE DART: no widget, no `TextEditingValue`. The composer widget reads its
/// own selection and hands the plain strings in, so every rule here is
/// exercisable without a tree — the same split `composer.dart` uses for the
/// keyboard.
library;

/// Which character opened a menu.
enum MenuTrigger {
  /// Skills and commands: `/`.
  slash('/'),

  /// File references: `@`.
  at('@');

  MenuTrigger(this.char);

  final String char;
}

/// A live menu token: the trigger, what has been typed into it, and where it is.
class MenuToken {
  const MenuToken({
    required this.trigger,
    required this.query,
    required this.start,
    required this.end,
  });

  final MenuTrigger trigger;

  /// The text between the trigger and the caret — what the menu filters by.
  final String query;

  /// Index of the trigger character.
  final int start;

  /// The caret, i.e. one past the last character of the query.
  final int end;

  @override
  String toString() =>
      'MenuToken(${trigger.char}, query: "$query", $start..$end)';

  @override
  bool operator ==(Object other) =>
      other is MenuToken &&
      other.trigger == trigger &&
      other.query == query &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(trigger, query, start, end);
}

/// Word characters: letters and digits in ANY script, plus underscore.
///
/// The unicode property escapes matter more here than they look. Written as
/// `[a-z0-9_]`, a Chinese character would count as punctuation, so
/// `请帮我看看/foo` would open the skills menu in the middle of a sentence —
/// and this app's default language is Chinese, which is exactly where that
/// would show up.
final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

bool _isWhitespace(String ch) => ch.trim().isEmpty;

/// Whether a trigger at [index] is allowed to open a menu.
///
/// The three carve-outs are the ones that make this rule worth having at all:
/// without them a path, a URL or a `//` comment would open a menu every time
/// someone typed one.
bool _boundaryOk(String text, int index, MenuTrigger trigger) {
  if (index == 0) return true;
  final prev = text[index - 1];
  if (_isWhitespace(prev)) return true;
  // Mid-word: `foo/bar`, `someone@host`.
  if (_wordChar.hasMatch(prev)) return false;

  if (trigger == MenuTrigger.slash) {
    // The second slash of `//`.
    if (prev == '/') return false;
    // A URL scheme separator: `https:/…`, but not `see :/foo` after a space.
    if (prev == ':' && index >= 2 && !_isWhitespace(text[index - 2])) {
      return false;
    }
  }
  return true;
}

/// Reads the menu token under the caret, or null when there is none.
///
/// Scans back to the start of the token (the first whitespace) and then looks
/// for the trigger NEAREST the caret, so that a `/` typed after a path is judged
/// on its own boundary rather than on the one at the head of the line.
MenuToken? readMenuToken({required String text, required int caret}) {
  if (caret < 0 || caret > text.length) return null;

  var tokenStart = caret;
  while (tokenStart > 0 && !_isWhitespace(text[tokenStart - 1])) {
    tokenStart--;
  }

  for (var i = caret - 1; i >= tokenStart; i--) {
    final trigger = switch (text[i]) {
      '/' => MenuTrigger.slash,
      '@' => MenuTrigger.at,
      _ => null,
    };
    if (trigger == null) continue;
    if (!_boundaryOk(text, i, trigger)) continue;
    return MenuToken(
      trigger: trigger,
      query: text.substring(i + 1, caret),
      start: i,
      end: caret,
    );
  }
  return null;
}

/// Whether a token that was typed should actually OPEN a menu.
///
/// Two suppressions, and both come from the same insight: `/` means different
/// things in different panes, and a menu that appears while somebody is typing
/// a path is a menu in the way.
///
///  1. **A slash token with another slash inside it is a PATH.** `cd /usr/local`
///     used to open the skills list, and so did every absolute path anybody
///     typed. No skill is called `usr/local`, so there is nothing to lose.
///  2. **A pane with no agent has no skills.** `/` in a plain terminal is a path
///     separator; the skills and MCP lists are an agent's vocabulary, and
///     offering them in a shell is offering a menu of things that shell cannot
///     do. The pane's own report says which it is — `pane.list` leaves `agent`
///     empty for a shell (measured on herdr 0.9.0).
///
/// `@` is NOT suppressed: a file reference is useful in a shell too. What
/// changes there is what a pick INSERTS — see [fileReferenceText].
bool shouldOpenMenu(MenuToken token, {required bool agentPane}) {
  if (token.trigger != MenuTrigger.slash) return true;
  if (token.query.contains('/')) return false;
  return agentPane;
}

/// What a picked file becomes in the message.
///
/// The `@` is a MENTION — syntax the agent resolves. A shell resolves nothing of
/// the sort, so a shell pane gets the bare path, which is what it can actually
/// use (`cat <path>`, `git add <path>`).
String fileReferenceText(String path, {required bool agentPane}) =>
    agentPane ? '@$path' : path;

/// What the field becomes when [pick] is chosen for [token].
///
/// [pick] is the WHOLE replacement, trigger character included — `/code-review`
/// for a skill, `@lib/main.dart` for a file. The menu knows what it is inserting,
/// and a rule here that guessed "add a slash, unless it is a file" would be a
/// second copy of that knowledge in the one place that cannot see the candidate.
///
/// The trailing space is not decoration: it ends the token, which closes the
/// menu, and it is what makes a pick read as a word the user typed rather than a
/// chip glued to the next one. It is skipped when the field already has a space
/// there — picking in the middle of a sentence should not leave a double.
({String text, int caret}) applyPick({
  required String text,
  required MenuToken token,
  required String pick,
}) {
  final rest = text.substring(token.end);
  // A space is added unless the field already has whitespace there — and at the
  // END of the text it always is, because that is where the menu was opened: the
  // next thing typed must not glue itself to the pick (`/code-reviewfoo`).
  final separator = rest.isEmpty || !_isWhitespace(rest[0]) ? ' ' : '';
  final inserted = '$pick$separator';
  return (
    text: text.substring(0, token.start) + inserted + rest,
    caret: token.start + inserted.length,
  );
}

/// The index a menu is opened at when it is opened by a BUTTON rather than by
/// typing the trigger.
int menuInsertionPoint({required String text, required int caret}) {
  if (caret < 0 || caret > text.length) return text.length;
  return caret;
}

/// Ranks named candidates by a menu query.
///
/// The match is an **ordered subsequence**, case-insensitively: `cr` finds
/// `code-review`, and `crv` does too. Prefix hits come first, then the best
/// alignment, then the order the candidates arrived in — so an empty query is
/// the list itself, and a short query does not shuffle a catalogue around on
/// every keystroke.
///
/// This is the ranking the harness's own `/` menu uses; the point of matching it
/// is that `/` and `@` feel the same here as in every other client this user
/// has, and `cr` meaning `code-review` is muscle memory rather than a discovery.
List<T> rankByName<T>(List<T> items, String query, String Function(T) nameOf) {
  final needle = query.toLowerCase();
  if (needle.isEmpty) return items;

  final ranked = <({T item, int index, bool prefix, int score})>[];
  for (var index = 0; index < items.length; index++) {
    final name = nameOf(items[index]).toLowerCase();
    final score = _alignmentScore(name, needle);
    if (score == null) continue;
    ranked.add((
      item: items[index],
      index: index,
      prefix: name.startsWith(needle),
      score: score,
    ));
  }
  ranked.sort((a, b) {
    if (a.prefix != b.prefix) return a.prefix ? -1 : 1;
    if (a.score != b.score) return b.score - a.score;
    return a.index - b.index;
  });
  return [for (final row in ranked) row.item];
}

/// Weight for a match at a name's start or after a separator.
int _boundaryBonus(String name, int index) {
  if (index == 0) return 8;
  final prev = name[index - 1];
  return prev == '-' || prev == '_' ? 8 : 0;
}

/// The strongest ordered-subsequence alignment of [needle] in [name].
///
/// A tiny dynamic program over (name × needle): a character that continues the
/// previous match scores best, a gapped match scores less, and every skipped or
/// leading character costs — which is what makes `cod` prefer `code-review` over
/// `cloudflare-one-durable-objects`. Null when the needle is not a subsequence
/// at all.
int? _alignmentScore(String name, String needle) {
  if (needle.length > name.length) return null;
  const noMatch = -1 << 30;

  var previous = List<int>.filled(name.length, noMatch);
  for (var i = 0; i < name.length; i++) {
    if (name[i] == needle[0]) previous[i] = 1 + _boundaryBonus(name, i) - i;
  }

  for (var q = 1; q < needle.length; q++) {
    final current = List<int>.filled(name.length, noMatch);
    var left = noMatch;
    var leftLeft = noMatch;
    var bestGapped = noMatch;
    for (var i = 0; i < name.length; i++) {
      if (leftLeft != noMatch && leftLeft + i - 2 > bestGapped) {
        bestGapped = leftLeft + i - 2;
      }
      if (name[i] == needle[q]) {
        final bonus = 1 + _boundaryBonus(name, i);
        var score = noMatch;
        if (left != noMatch) score = left + bonus + 4;
        if (bestGapped != noMatch) {
          final gapped = bestGapped + bonus + 1 - i;
          if (gapped > score) score = gapped;
        }
        current[i] = score;
      }
      leftLeft = left;
      left = previous[i];
    }
    previous = current;
  }

  var best = noMatch;
  for (final score in previous) {
    if (score > best) best = score;
  }
  return best == noMatch ? null : best;
}
