import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_pocket/domain/files/file_kind.dart';
import 'package:herdr_pocket/domain/files/preview_kind.dart';

/// Tests for "what do I do with this file", decided from the name alone.
///
/// These are the decisions a screenshot cannot show: a `.png` sent down the
/// text channel would come back as a "binary file" notice, a `.pdf` sent down
/// the byte channel would be an image decode failure, and neither would look
/// broken in a diff.
void main() {
  group('previewKindFor', () {
    test('an extensionless name is text, not a guess', () {
      expect(previewKindFor('LICENSE'), FilePreviewKind.text);
      expect(previewKindFor('Makefile'), FilePreviewKind.text);
    });

    test('Markdown is recognised in both spellings and both cases', () {
      expect(previewKindFor('README.md'), FilePreviewKind.markdown);
      expect(previewKindFor('notes.markdown'), FilePreviewKind.markdown);
      expect(previewKindFor('CHANGELOG.MD'), FilePreviewKind.markdown);
    });

    test('the same Markdown rules apply as the file tree offers', () {
      // The two halves of one decision: the tree offers a Markdown preview for
      // exactly the names this page renders as one. `mdx` is excluded there and
      // has to be excluded here.
      expect(previewKindFor('docs.md.txt'), FilePreviewKind.text);
      expect(previewKindFor('old.md.bak'), FilePreviewKind.text);
      expect(previewKindFor('component.mdx'), FilePreviewKind.text);
    });

    test('the formats the engine can decode are images', () {
      for (final name in const [
        'shot.png',
        'photo.JPG',
        'photo.jpeg',
        'anim.gif',
        'anim.webp',
        'old.bmp',
      ]) {
        expect(previewKindFor(name), FilePreviewKind.image, reason: name);
      }
    });

    test('formats the engine cannot decode are NOT offered as images', () {
      // A `.ico` or `.heic` that opens an image view and fails to decode is
      // worse than one that says it is a binary file: the reader is left with a
      // broken picture and no explanation.
      expect(previewKindFor('favicon.ico'), FilePreviewKind.text);
      expect(previewKindFor('IMG_0001.heic'), FilePreviewKind.text);
      expect(previewKindFor('scan.tiff'), FilePreviewKind.text);
    });

    test('an SVG counts as an image kind but not as a raster one', () {
      // SVG is a picture written in text: the kind drives the VIEW, the raster
      // question drives which channel reads it.
      expect(previewKindFor('logo.svg'), FilePreviewKind.image);
      expect(isSvgName('logo.svg'), isTrue);
      expect(isRasterImageName('logo.svg'), isFalse);
      expect(isRasterImageName('logo.png'), isTrue);
    });

    test('a PDF is its own answer', () {
      expect(previewKindFor('report.pdf'), FilePreviewKind.pdf);
      expect(isPdfName('report.PDF'), isTrue);
      expect(isPdfName('report.pdfx'), isFalse);
    });

    test('only the last extension counts', () {
      expect(previewKindFor('backup.png.tar'), FilePreviewKind.text);
      expect(previewKindFor('shot.png.bak'), FilePreviewKind.text);
    });

    test('a dotfile has no extension at all', () {
      // `.gitignore` is a file whose NAME begins with a dot, not a file of type
      // `gitignore`. Reading it as one would make `.png` the drawing tool.
      expect(previewKindFor('.gitignore'), FilePreviewKind.text);
      expect(previewKindFor('.env'), FilePreviewKind.text);
      expect(isRasterImageName('.png'), isFalse);
      expect(isRasterImageName('png'), isFalse);
    });
  });

  group('extensionOf', () {
    test('is the lowercased last extension', () {
      expect(extensionOf('Main.DART'), 'dart');
      expect(extensionOf('archive.tar.gz'), 'gz');
    });

    test('is null for names that have none', () {
      expect(extensionOf('Makefile'), isNull);
      expect(extensionOf('.gitignore'), isNull);
      expect(extensionOf('notes.'), isNull);
      expect(extensionOf(''), isNull);
    });
  });
}
