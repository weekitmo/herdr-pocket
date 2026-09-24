import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/files/source_language.dart';
import 'package:herdr_pocket/domain/highlight/syntax.dart';

/// Tests for the name → grammar table.
///
/// The bug this file exists for is "that one file type is never coloured, and
/// nobody notices for a year": a typo in the table is invisible on every screen
/// but the one that shows that language, and the failure is silent — the file
/// still opens, in plain text.
void main() {
  group('sourceLanguageFor', () {
    test('every language the user asked for by name resolves', () {
      expect(sourceLanguageFor('main.py'), 'python');
      expect(sourceLanguageFor('app.ts'), 'typescript');
      expect(sourceLanguageFor('main.go'), 'go');
      expect(sourceLanguageFor('lib.rs'), 'rust');
      expect(sourceLanguageFor('index.js'), 'javascript');
      expect(sourceLanguageFor('Program.cs'), 'cs');
      expect(sourceLanguageFor('package.json'), 'json');
      expect(sourceLanguageFor('ci.yaml'), 'yaml');
      expect(sourceLanguageFor('Cargo.toml'), 'ini');
      expect(sourceLanguageFor('Dockerfile'), 'dockerfile');
    });

    test('EVERY value in the table is a registered grammar', () {
      // The guard against the silent failure described above. It walks the
      // table the way the app does — by name — so a value the registry does not
      // know is caught here rather than on a phone.
      const names = [
        'x.dart', 'x.sh', 'x.bash', 'x.zsh', 'x.ksh', 'x.bats', 'x.env',
        'x.py', 'x.pyi', 'x.pyw', 'x.rb', 'x.ru', 'x.gemspec', 'x.pl', 'x.pm',
        'x.lua', 'x.ps1', 'x.psm1', 'x.psd1', 'x.r', 'x.rmd', 'x.jl', 'x.go',
        'x.rs', 'x.c', 'x.cc', 'x.cpp', 'x.cxx', 'x.hpp', 'x.hh', 'x.hxx',
        'x.cs', 'x.java', 'x.kt', 'x.kts', 'x.scala', 'x.sbt', 'x.swift',
        'x.mm', 'x.vb', 'x.hs', 'x.lhs', 'x.ml', 'x.mli', 'x.ex', 'x.exs',
        'x.erl', 'x.hrl', 'x.clj', 'x.cljs', 'x.cljc', 'x.edn', 'x.js', 'x.jsx',
        'x.mjs', 'x.cjs', 'x.ts', 'x.tsx', 'x.mts', 'x.cts', 'x.json', 'x.jsonc',
        'x.ipynb', 'x.html', 'x.htm', 'x.xhtml', 'x.xml', 'x.plist', 'x.xsl',
        'x.xslt', 'x.svg', 'x.css', 'x.scss', 'x.less', 'x.vue', 'x.yaml',
        'x.yml', 'x.toml', 'x.ini', 'x.cfg', 'x.conf', 'x.service', 'x.properties',
        'x.gradle', 'x.groovy', 'x.graphql', 'x.gql', 'x.proto', 'x.sql',
        'x.md', 'x.markdown', 'x.diff', 'x.patch', 'x.vim',
      ];
      for (final name in names) {
        final id = sourceLanguageFor(name);
        expect(id, isNotNull, reason: '$name has no language');
        expect(
          hasGrammar(id),
          isTrue,
          reason: '$name resolved to "$id", which is not a registered grammar',
        );
      }
    });

    test('the special filenames are filenames, not extensions', () {
      expect(sourceLanguageFor('Makefile'), 'makefile');
      expect(sourceLanguageFor('makefile'), 'makefile');
      expect(sourceLanguageFor('Makefile.am'), 'makefile');
      expect(sourceLanguageFor('Gemfile'), 'ruby');
      expect(sourceLanguageFor('Rakefile'), 'ruby');
      expect(sourceLanguageFor('Jenkinsfile'), 'groovy');
      expect(sourceLanguageFor('CMakeLists.txt'), 'cmake');
      expect(sourceLanguageFor('nginx.conf'), 'nginx');
    });

    test('a Dockerfile is one whatever it is called around the edges', () {
      expect(sourceLanguageFor('Dockerfile'), 'dockerfile');
      expect(sourceLanguageFor('Dockerfile.dev'), 'dockerfile');
      expect(sourceLanguageFor('dev.Dockerfile'), 'dockerfile');
      // But a name that merely CONTAINS it is not.
      expect(sourceLanguageFor('DockerfileX'), isNull);
      expect(sourceLanguageFor('not-a-dockerfile.txt'), isNull);
    });

    test('dotfiles are shell files where they are shell files', () {
      expect(sourceLanguageFor('.bashrc'), 'bash');
      expect(sourceLanguageFor('.bash_profile'), 'bash');
      expect(sourceLanguageFor('.zshrc'), 'bash');
      expect(sourceLanguageFor('.env'), 'bash');
      expect(sourceLanguageFor('.env.local'), 'bash');
      expect(sourceLanguageFor('.vimrc'), 'vim');
      expect(sourceLanguageFor('.editorconfig'), 'ini');
      // And no grammar where there is none to have.
      expect(sourceLanguageFor('.gitignore'), isNull);
      expect(sourceLanguageFor('.envrc-not-really'), isNull);
    });

    test('an unknown name gets no grammar rather than a guess', () {
      // `.m` is the worked example: MATLAB and Objective-C, and the two
      // highlight differently. Guessing would put wrong colours on a file.
      expect(sourceLanguageFor('sim.m'), isNull);
      expect(sourceLanguageFor('Firmware.h'), isNull);
      expect(sourceLanguageFor('notes.txt'), isNull);
      expect(sourceLanguageFor('server.log'), isNull);
      expect(sourceLanguageFor('data.csv'), isNull);
      expect(sourceLanguageFor('main.tf'), isNull);
      expect(sourceLanguageFor('LICENSE'), isNull);
      expect(sourceLanguageFor(''), isNull);
    });

    test('the last extension is the one that counts', () {
      expect(sourceLanguageFor('notes.md.bak'), isNull);
      expect(sourceLanguageFor('main.dart.orig'), isNull);
    });

    test('is case-insensitive, because phones capitalise on their own', () {
      expect(sourceLanguageFor('MAIN.PY'), 'python');
      expect(sourceLanguageFor('Lib.RS'), 'rust');
      expect(sourceLanguageFor('DOCKERFILE'), 'dockerfile');
    });
  });
}
