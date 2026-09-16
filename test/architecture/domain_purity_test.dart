import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `lib/domain` must stay pure Dart.
///
/// This is not tidiness — it is what makes the most consequential logic in the
/// app testable without a Flutter binding, and portable enough to be checked
/// line-by-line against the semantics it was ported from. The moment a domain
/// file imports a Flutter type, the board's grouping and ordering rules can
/// only be tested through the widget layer, and they quietly become untestable.
///
/// See plannings/architecture.md section 6.
void main() {
  test('lib/domain imports nothing from Flutter', () {
    final domainDir = Directory('lib/domain');
    if (!domainDir.existsSync()) {
      fail('lib/domain is missing — the layering contract assumes it exists.');
    }

    // `dart:ui` counts as Flutter here even though it is not spelled
    // `package:flutter/`. It is the engine's own library — `Size`, `Rect`,
    // `Offset` — and a domain file that imports it can no longer be exercised
    // without a binding, which is the exact property this test protects. The
    // first version of this guard only looked for `package:flutter/`, so
    // `import 'dart:ui'` passed it while breaking the rule the file is named
    // after. Found while adding the pane-geometry types, which wanted `Size`.
    final offenders = <String, String>{};
    final files = domainDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('.g.dart'));

    final pattern = RegExp(
      r'''^\s*import\s+['"](package:flutter/|dart:ui)|^\s*export\s+['"](package:flutter/)''',
      multiLine: true,
    );

    for (final file in files) {
      final source = file.readAsStringSync();
      final match = pattern.firstMatch(source);
      if (match != null) {
        offenders[file.path] = (match.group(1) ?? match.group(2) ?? 'Flutter').trim();
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Domain files must not depend on Flutter:\n'
          '${offenders.entries.map((e) => '  ${e.key} -> ${e.value}').join('\n')}',
    );
  });

  test('lib/domain imports nothing from lib/data or lib/ui', () {
    final domainDir = Directory('lib/domain');
    if (!domainDir.existsSync()) return;

    final offenders = <String>[];
    for (final file
        in domainDir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      // Dependencies point inward: domain may not know about layers above it.
      if (RegExp(r"package:herdr_pocket/(data|ui|app)/").hasMatch(source)) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty, reason: 'Domain depends on outer layers: $offenders');
  });
}
