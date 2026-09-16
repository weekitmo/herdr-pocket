import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The no-Material rule is a hard product constraint, and a rule that lives in
/// prose gets violated the first time someone is in a hurry.
///
/// A lint cannot ban an import by path, so it is a test — and a failing test in
/// CI is a better enforcement mechanism than a code-review reminder.
///
/// WHY the rule exists (beyond the user asking): Material and Cupertino disagree
/// about almost everything visible — ripple vs highlight, elevation vs hairline,
/// 8-grid denser spacing, its own type ramp, its own colors. One Material widget
/// in the tree drags its ancestors' defaults with it and the app stops looking
/// like one system. See plannings/architecture.md ADR-004.
void main() {
  final libDir = Directory('lib');

  /// Every `.dart` file under lib/, excluding generated code.
  List<File> libFiles() {
    if (!libDir.existsSync()) return [];
    return libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('.g.dart'))
        .toList();
  }

  test('no file under lib/ imports Material', () {
    final offenders = <String>[];
    for (final file in libFiles()) {
      final source = file.readAsStringSync();
      // Match the import itself, not the word "Material" in a comment — the
      // comments in this codebase talk about Material constantly, on purpose.
      final importsMaterial = RegExp(
        r'''^\s*import\s+['"]package:flutter/material\.dart['"]''',
        multiLine: true,
      ).hasMatch(source);
      if (importsMaterial) offenders.add(file.path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These files import package:flutter/material.dart. '
          'herdr-pocket is a no-Material app (ADR-004). Use package:flutter/'
          'cupertino.dart, or build the widget from primitives.',
    );
  });

  test('no file under lib/ imports the Material icon font', () {
    final offenders = <String>[];
    for (final file in libFiles()) {
      final source = file.readAsStringSync();
      // `CupertinoIcons.add` contains the substring "Icons." and is NOT the
      // Material icon font. The lookbehind is what distinguishes the two: a
      // bare `Icons.` reference has nothing identifier-like before it.
      final usesMaterialIcons =
          RegExp(r'''^\s*import\s+['"]package:flutter/icons\.dart['"]''',
                  multiLine: true)
              .hasMatch(source) ||
          RegExp(r'(?<![A-Za-z0-9_])Icons\.').hasMatch(source);
      if (usesMaterialIcons) offenders.add(file.path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'The Material Icons font is not bundled '
          '(uses-material-design: false in pubspec.yaml). Referencing Icons.* '
          'would render tofu at runtime.',
    );
  });

  test('pubspec keeps uses-material-design disabled', () {
    // COMMENTS ARE STRIPPED FIRST, and that is not pedantry: this file's own
    // explanation of WHY the flag is off has to be able to name the flag. It
    // did, the naive `contains` matched the prose, and the guard failed on a
    // pubspec that was correct — a rule that fires on its own documentation is
    // a rule somebody deletes.
    final pubspec = File('pubspec.yaml')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('#'))
        .join('\n');

    expect(
      RegExp(r'^\s*uses-material-design\s*:\s*true', multiLine: true)
          .hasMatch(pubspec),
      isFalse,
      reason: 'Bundling the Material icon font contradicts ADR-004 '
          '(see plannings/findings.md section 37.7 for the measured cost).',
    );
    expect(
      pubspec.contains('uses-material-design: false'),
      isTrue,
      reason: 'the flag has to be stated, not merely left at its default: the '
          'default is true, and a dependency declaring true was what produced '
          'the confusion in the first place',
    );
  });
}
