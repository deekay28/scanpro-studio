import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc, viewerText;

late PdfiumEngine engine;
PdfiumSession op(Uint8List b, {String? password}) => engine.open(b, password: password) as PdfiumSession;

/// Every stream of the file, decompressed when Flate-encoded, plus the raw
/// bytes: anything a forensic look at the file could find.
String everythingInFile(Uint8List bytes) {
  final sb = StringBuffer(latin1.decode(bytes, allowInvalid: true));
  final s = latin1.decode(bytes, allowInvalid: true);
  var i = 0;
  while (true) {
    final start = s.indexOf('stream', i);
    if (start < 0) break;
    var dataStart = start + 6;
    if (s.startsWith('\r\n', dataStart)) {
      dataStart += 2;
    } else if (s.startsWith('\n', dataStart)) {
      dataStart += 1;
    }
    final end = s.indexOf('endstream', dataStart);
    if (end < 0) break;
    try {
      sb.write(latin1.decode(ZLibDecoder().convert(bytes.sublist(dataStart, end)), allowInvalid: true));
    } catch (_) {}
    i = end + 9;
  }
  return sb.toString();
}

Uint8List secretPdf() => sfDoc((d) {
      d.documentInformation.title = 'Secret 4111222233334444 file';
      final page = d.pages.add();
      final f = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12);
      page.graphics.drawString('Account number 4111222233334444 belongs to John Smith', f, bounds: const Rect.fromLTWH(40, 40, 500, 20));
      page.graphics.drawString('Keep this line', f, bounds: const Rect.fromLTWH(40, 70, 500, 20));
      final im = img.Image(width: 200, height: 100)..clear(img.ColorRgb8(255, 255, 0));
      page.graphics.drawImage(sf.PdfBitmap(Uint8List.fromList(img.encodePng(im))), const Rect.fromLTWH(40, 120, 200, 100));
      page.annotations.add(sf.PdfUriAnnotation(bounds: const Rect.fromLTWH(130, 40, 120, 16), uri: 'https://bank.example/4111222233334444'));
    });

void main() {
  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    engine = PdfiumEngine(unicodeFont: freeSans);
  });

  test('ACCEPTANCE 12: true redaction removes text, pixels, links and metadata, and is verified', () {
    final src = secretPdf();
    final s = op(src);
    final words = s.content(0).lines.expand((l) => l.words).toList();
    final secret = words.firstWhere((w) => w.text == '4111222233334444');
    final r = s.redact({
      0: [RedactArea(secret.box.inflate(1)), const RedactArea(Rect.fromLTWH(60, 140, 50, 40))]
    });
    s.close();
    expect(r.verified, isTrue, reason: r.leaks.join(','));
    expect(r.charsRemoved, 16);
    expect(r.imagesRedacted, 1);
    expect(r.annotationsRemoved, 1);
    expect(r.rasterizedPages, isEmpty);
    final text = viewerText(r.bytes);
    expect(text, isNot(contains('4111')));
    expect(text, allOf(contains('Account number'), contains('belongs to John Smith'), contains('Keep this line')));
    final forensic = everythingInFile(r.bytes);
    expect(forensic, isNot(contains('4111222233334444')), reason: 'not in any stream, metadata or URI');
    expect(forensic, isNot(contains('Secret')), reason: 'document metadata dropped');
    // The redacted image area is black in the image data itself.
    final out = op(r.bytes);
    expect(out.pageSize(0), const Size(595, 842), reason: 'page size kept in the rebuilt file');
    expect(out.annotations(), isEmpty);
    final px = out.renderOriginal(0, 1);
    int at(int x, int y) => px.rgba[(y * px.width + x) * 4];
    expect(at(85, 160), lessThan(30), reason: 'redacted pixels');
    expect(at(200, 200), greaterThan(200), reason: 'rest of the image intact');
    // Original file untouched.
    expect(viewerText(src), contains('4111222233334444'));
    out.close();
  });

  test('redaction rasterises pages whose content cannot be edited precisely (form XObject)', () {
    final src = sfDoc((d) {
      final page = d.pages.add();
      final t = sf.PdfTemplate(300, 40);
      t.graphics!.drawString('Template secret 987654', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(0, 0, 300, 20));
      page.graphics.drawPdfTemplate(t, const Offset(40, 40));
      page.graphics.drawString('Visible footer', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 300, 300, 20));
    });
    final s = op(src);
    final w = s.content(0).lines.expand((l) => l.words).firstWhere((w) => w.text == '987654');
    final r = s.redact({
      0: [RedactArea(w.box.inflate(1))]
    });
    s.close();
    expect(r.rasterizedPages, [0]);
    expect(r.verified, isTrue);
    expect(everythingInFile(r.bytes), isNot(contains('987654')));
    expect(r.report.join(' '), contains('converted to images'));
  });

  test('image optimisation keeps text, links and form fields; reports sizes', () {
    final src = sfDoc((d) {
      final page = d.pages.add();
      page.graphics.drawString('Searchable text stays', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 400, 20));
      final noisy = img.Image(width: 1600, height: 1200);
      for (final p in noisy) {
        p
          ..r = (p.x * 7 + p.y * 3) % 256
          ..g = (p.x * p.y) % 256
          ..b = (p.y * 5) % 256;
      }
      page.graphics.drawImage(sf.PdfBitmap(Uint8List.fromList(img.encodePng(noisy))), const Rect.fromLTWH(40, 80, 400, 300));
      page.annotations.add(sf.PdfUriAnnotation(bounds: const Rect.fromLTWH(40, 40, 100, 14), uri: 'https://example.org'));
      d.form.fields.add(sf.PdfTextBoxField(page, 'name', const Rect.fromLTWH(40, 420, 200, 20), text: 'Alice'));
    });
    final s = op(src);
    final r = s.optimizeImages(const ImageOptimizeOptions(maxDpi: 96, quality: 60));
    s.close();
    expect(r.imagesRecompressed, 1);
    expect(r.bytes.length, lessThan(src.length * 0.5));
    expect(viewerText(r.bytes), contains('Searchable text stays'));
    final out = op(r.bytes);
    expect(out.annotations().length, 2, reason: 'link and form widget kept');
    final im = out.analyze(0).images.single;
    expect(im.pixelWidth, closeTo(400 * 96 / 72, 2), reason: 'downsampled to 96 dpi');
    out.close();
    final d = sf.PdfDocument(inputBytes: r.bytes);
    expect((d.form.fields[0] as sf.PdfTextBoxField).text, 'Alice');
    d.dispose();
  });

  test('repair, lined/grid pages and page replacement', () {
    final good = sfDoc((d) {
      for (var i = 0; i < 3; i++) {
        d.pages.add().graphics.drawString('Page $i', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 200, 20));
      }
    });
    // Break the cross-reference table offsets.
    final broken = Uint8List.fromList(good);
    final s = latin1.decode(broken);
    final x = s.lastIndexOf('xref');
    if (x > 0) {
      for (var i = x + 30; i < x + 120 && i < broken.length; i++) {
        if (broken[i] >= 0x30 && broken[i] <= 0x39) broken[i] = 0x39;
      }
    }
    final fixed = PdfiumSession.repair(broken);
    expect(op(fixed).pageCount, 3);
    expect(viewerText(fixed), contains('Page 2'));
    final s1 = op(good);
    final withPages = s1.insertPatternPages(const [PatternPage(1, PagePattern.lined), PatternPage(3, PagePattern.grid)]);
    s1.close();
    final s2 = op(withPages);
    expect(s2.pageCount, 5);
    expect(s2.content(1).rules.length, greaterThan(20), reason: 'ruled lines drawn');
    s2.close();
    final other = sfDoc((d) => d.pages.add().graphics.drawString('Replacement', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 200, 20)));
    final s3 = op(good);
    final replaced = s3.replacePages(other, null, {1: 0});
    s3.close();
    final pages = PdfiumSession.pageTexts(replaced);
    expect(pages.length, 3);
    expect(pages[1], contains('Replacement'));
    expect(pages[2], contains('Page 2'));
  });

  test('outline, search and annotation listing', () {
    final src = sfDoc((d) {
      for (var i = 0; i < 3; i++) {
        d.pages.add().graphics.drawString('Chapter $i body with keyword alpha', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 400, 20));
      }
      final b = d.bookmarks.add('Chapter 2');
      b.destination = sf.PdfDestination(d.pages[2]);
      final c = b.add('Section 2.1');
      c.destination = sf.PdfDestination(d.pages[2]);
      d.pages[0].annotations.add(sf.PdfPopupAnnotation(const Rect.fromLTWH(10, 10, 20, 20), 'A note', author: 'Reviewer'));
    });
    final s = op(src);
    final o = s.outline();
    expect(o.map((e) => (e.title, e.page, e.level)), [('Chapter 2', 2, 0), ('Section 2.1', 2, 1)]);
    final hits = s.search('alpha');
    expect(hits.length, 3);
    expect(hits.first.rects, isNotEmpty);
    expect(hits.first.context, contains('keyword alpha'));
    final a = s.annotations();
    expect(a.single.contents, 'A note');
    expect(a.single.author, 'Reviewer');
    s.close();
  });
}
