/// Reading "what is this agent asking me?" out of a screen of terminal text.
///
/// The board can already tell that an agent NEEDS you (see `agent_group.dart`),
/// but not WHAT it wants — the user has to open the full TUI and find the prompt
/// themselves. `agent.read` hands us that screen as text; this file turns it
/// into a question, an option list, and an honest confidence level.
///
/// Everything here is a heuristic over somebody else's TUI. So the rule is
/// **never invent**: when the shape is not recognised, [QuestionConfidence.none]
/// is returned and the caller is expected to show the raw lines plus a single
/// "go answer it in the terminal" action rather than offering buttons that might
/// press the wrong thing.
library;

/// One answer the agent is offering.
class AgentOption {
  const AgentOption({
    required this.key,
    required this.label,
    this.needsEnter = false,
    this.isCursor = false,
  });

  /// The literal key to send. For a numbered menu this is the digit; for a
  /// `(y/n)` prompt it is the letter.
  final String key;

  /// What the option says, for display.
  final String label;

  /// Whether the key alone is the whole answer.
  ///
  /// This distinction is load-bearing and it is NOT cosmetic. A TUI menu
  /// (Claude Code's permission prompt, say) acts on the digit directly, so
  /// sending `1` and then `enter` would confirm twice — the second press being
  /// an unintended answer to whatever came next. A raw `(y/n)` prompt in the
  /// PTY line discipline is the opposite: the letter does nothing until Enter
  /// arrives. Getting this backwards is how a "helpful" button deletes a file.
  final bool needsEnter;

  /// True when the TUI drew its selection cursor on this row. Used only to
  /// break ambiguity — which option Enter would pick.
  final bool isCursor;

  @override
  String toString() => 'AgentOption($key, $label)';
}

/// How much of the screen we actually understood.
enum QuestionConfidence {
  /// A question and at least two options were both found.
  high,

  /// Something was found — options without a question, or a question without
  /// options, or a single option. Worth showing, not worth trusting blindly.
  low,

  /// Nothing recognisable. Show the raw tail and stop guessing.
  none,
}

/// What an agent is waiting on.
class AgentQuestion {
  const AgentQuestion({
    required this.prompt,
    required this.options,
    required this.confidence,
    required this.rawLines,
    this.isYesNo = false,
  });

  /// The sentence being asked, already demangled. Null when none was found.
  final String? prompt;

  /// Answers the agent offers, in screen order. Empty when none were parsed.
  final List<AgentOption> options;

  final QuestionConfidence confidence;

  /// The last few non-chrome lines, ALWAYS present.
  ///
  /// This is the fallback that keeps the feature honest: even at
  /// [QuestionConfidence.none] the user gets to read the actual screen and
  /// decide for themselves, instead of being told "sorry" by a card that has
  /// the text in hand.
  final List<String> rawLines;

  /// True when the prompt was an inline `(y/n)` rather than a menu.
  final bool isYesNo;

  /// Whether buttons may be offered at all.
  bool get isActionable =>
      confidence != QuestionConfidence.none && options.isNotEmpty;

  /// The whole question as one line, for a card subtitle.
  String? get summary {
    final text = prompt?.trim();
    if (text == null || text.isEmpty) return null;
    // One line only: the card is a glance, the sheet is the detail.
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= 120 ? collapsed : '${collapsed.substring(0, 119)}…';
  }
}

/// Unicode private use area — Nerd Font icons live here.
///
/// A TUI status bar draws its icons from this range, and our bundled font has
/// no glyphs for most of it, so the daemon's text view renders them as
/// half-width kana (`ｭ ｺ 7 ｫ ｸ`). Left in, they make an otherwise clean
/// question look broken. There is nothing to lose by dropping them: they are
/// decoration, never content.
final _privateUse = RegExp(r'[\uE000-\uF8FF]');

/// CSI sequences (`ESC [ … final-byte`) and OSC sequences (`ESC ] … BEL|ST`).
///
/// `agent.read` defaults to `strip_ansi: true`, so this is belt-and-braces for
/// the `format: ansi` path and for daemons that ignore the flag. Removing them
/// here means the parser never has to think about them.
final _ansi = RegExp(
  r'\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
);

/// Box-drawing characters a TUI frame draws around its content.
const _boxChars = '│┃║|╭╮╰╯┌┐└┘─━├┤┬┴┼═╔╗╚╝';

/// Characters a TUI uses to point at the currently selected row.
const _cursorChars = '❯>→▶»*';

/// Lines matching these are the agent's own chrome, not its message.
final _chromePatterns = <RegExp>[
  RegExp('tok/s', caseSensitive: false),
  RegExp(r'\bTTFB\b', caseSensitive: false),
  RegExp(r'^\s*[↑↓]\s*\d'), // ↑0 ↓0 — the pi/hermes token counters
  RegExp(r'^\s*\[[^\]]*@[^\]]*\]'), // [gw-ai-openai/deepseek-flash @max]
  RegExp(r'^\s*\d+%\s*(?:context|ctx)\b', caseSensitive: false),
];

/// `1. Yes` / `2) No, and don't ask again` / `❯ 3、No`.
///
/// Deliberately narrow: a bare digit at the start of a line is not an option
/// (`2026-09-14` and `80 columns` both start with digits), so a separator is
/// required.
final _optionLine = RegExp(r'^(\d{1,2})\s*[.)、]\s*(\S.*)$');
final _optionCursor = RegExp(r'^([❯>→▶»*])\s*');

/// `(y/n)`, `[Y/n]`, `[y/N]` — an inline yes/no, which behaves differently from
/// a menu (see [AgentOption.needsEnter]).
final _yesNo = RegExp(r'[(\[]\s*([yYnN])\s*/\s*([yYnN])\s*[)\]]');

/// Parses a screen of terminal text into the question it is asking.
///
/// [lines] is bottom-up irrelevant; give it in reading order. The parser looks
/// near the BOTTOM, because that is where every TUI puts its prompt — and
/// because the alternative (scanning a long scrollback) finds "1. …" inside
/// the agent's own prose, which is the failure mode that makes the whole idea
/// dangerous.
///
/// [searchDepth] bounds how far up the option block is allowed to start. A
/// prompt whose options have scrolled far above the status bar is not a prompt
/// we should be pressing buttons for.
AgentQuestion parseAgentQuestion(
  List<String> lines, {
  int searchDepth = 20,
  int contextLines = 6,
}) {
  final clean = <String>[
    for (final raw in lines)
      raw.replaceAll(_ansi, '').replaceAll(_privateUse, ' ').trimRight(),
  ];

  // Find where the content ends: everything below this is the agent's chrome.
  var end = clean.length;
  while (end > 0 && _isChrome(clean[end - 1])) {
    end--;
  }

  final content = clean.sublist(0, end);
  final rawLines = <String>[
    for (final line in content.reversed)
      if (line.trim().isNotEmpty) line,
  ].take(contextLines).toList().reversed.toList(growable: false);

  if (content.isEmpty) {
    return const AgentQuestion(
      prompt: null,
      options: [],
      confidence: QuestionConfidence.none,
      rawLines: [],
    );
  }

  // Walk UP from the bottom collecting a contiguous block of option lines.
  //
  // Contiguity is the discriminator. The agent's answer to a previous question
  // often contains numbered steps, and those sit far above a prompt wrapped in
  // blank lines; requiring the run to touch the bottom of the content keeps the
  // two apart without needing to understand either.
  final options = <AgentOption>[];
  var firstOptionIndex = -1;
  var isYesNo = false;
  var skippedTail = 0;

  for (var i = content.length - 1; i >= 0 && i >= content.length - searchDepth; i--) {
    final line = content[i];
    final stripped = _stripFrame(line);
    final trimmed = stripped.trim();

    if (trimmed.isEmpty) {
      // A blank line inside a menu block is fine (Claude Code separates its
      // boxed questions that way); a blank line BEFORE any option found so far
      // would break contiguity, so only tolerate a little trailing slack.
      if (options.isEmpty) {
        if (++skippedTail > 2) break;
      }
      continue;
    }

    // The cursor glyph sits to the LEFT of the digit (`❯ 1. Yes`), so it has to
    // come off before the option pattern — whose first character is the number —
    // can see the number at all.
    final hasCursor = _hasCursor(trimmed);
    final body = hasCursor ? trimmed.replaceFirst(_optionCursor, '').trim() : trimmed;

    final match = _optionLine.firstMatch(body);
    if (match != null) {
      options.insert(
        0,
        AgentOption(
          key: match.group(1)!,
          label: match.group(2)!.trim(),
          isCursor: hasCursor,
        ),
      );
      firstOptionIndex = i;
      continue;
    }

    // A cursor-marked line with no number is a highlight, not an option.
    if (options.isEmpty && hasCursor) continue;

    break;
  }

  // Yes/no style: no numbered block, but the tail line carries `(y/n)`.
  if (options.isEmpty) {
    for (var i = content.length - 1; i >= 0 && i >= content.length - searchDepth; i--) {
      final match = _yesNo.firstMatch(_stripFrame(content[i]));
      if (match == null) continue;
      isYesNo = true;
      firstOptionIndex = i;
      // Uppercase in the pattern is the default, but we do not encode a
      // default: pressing a key is the user's decision, not ours.
      options.addAll([
        AgentOption(key: match.group(1)!.toLowerCase(), label: match.group(1)!, needsEnter: true),
        AgentOption(key: match.group(2)!.toLowerCase(), label: match.group(2)!, needsEnter: true),
      ]);
      break;
    }
  }

  final prompt = _findPrompt(content, firstOptionIndex, isYesNo: isYesNo);

  final confidence = switch ((prompt, options.length)) {
    (final String _, final n) when n >= 2 => QuestionConfidence.high,
    (final String _, final n) when n == 1 => QuestionConfidence.low,
    (final String _, 0) => QuestionConfidence.low,
    (null, final n) when n > 0 => QuestionConfidence.low,
    _ => QuestionConfidence.none,
  };

  return AgentQuestion(
    prompt: prompt,
    options: List.unmodifiable(options),
    confidence: confidence,
    rawLines: rawLines,
    isYesNo: isYesNo,
  );
}

/// The sentence above the options.
///
/// Prefers the nearest line that actually asks something; falls back to the
/// nearest non-empty line, because plenty of prompts end in `:` or are
/// questions phrased without a mark. Returning null is fine — the caller shows
/// raw lines then.
String? _findPrompt(List<String> content, int optionIndex, {required bool isYesNo}) {
  // A `(y/n)` prompt asks its question ON the option line: "Continue? (y/n)".
  if (isYesNo && optionIndex >= 0) {
    final inline = _stripFrame(content[optionIndex]).trim();
    return inline.isEmpty ? null : inline;
  }

  // No options found. Only a REAL question mark counts here, and only on the
  // last real line: with no option block there is nothing else tying a
  // sentence to "this agent is waiting on you", and a closing remark like
  // "All tests pass." must not be dressed up as a question. Refusing to look
  // further up is the point — a question three screens back is history, not a
  // prompt.
  if (optionIndex < 0) {
    for (var i = content.length - 1; i >= 0; i--) {
      final text = _stripFrame(content[i]).trim();
      if (text.isEmpty || _isChrome(text) || _isBoxOnly(text)) continue;
      return text.contains('?') || text.contains('？') ? text : null;
    }
    return null;
  }

  var scanned = 0;
  for (var i = optionIndex - 1; i >= 0 && scanned < 8; i--, scanned++) {
    final text = _stripFrame(content[i]).trim();
    if (text.isEmpty) continue;
    if (_isChrome(text)) continue;
    // A frame edge is not a sentence.
    if (_isBoxOnly(text)) continue;
    return text;
  }
  return null;
}

/// Removes one layer of TUI framing from a line: leading/trailing box glyphs.
String _stripFrame(String line) {
  var text = line.trim();
  while (text.isNotEmpty && _boxChars.contains(text[0])) {
    text = text.substring(1).trimLeft();
  }
  while (text.isNotEmpty && _boxChars.contains(text[text.length - 1])) {
    text = text.substring(0, text.length - 1).trimRight();
  }
  return text;
}

bool _hasCursor(String line) =>
    line.trim().isNotEmpty && _cursorChars.contains(line.trim()[0]);

bool _isBoxOnly(String text) =>
    text.runes.every((r) => _boxChars.contains(String.fromCharCode(r)) || r == 0x20);

bool _isChrome(String line) {
  final text = line.trim();
  if (text.isEmpty) return true;
  if (_isBoxOnly(text)) return true;
  for (final pattern in _chromePatterns) {
    if (pattern.hasMatch(text)) return true;
  }
  return false;
}
