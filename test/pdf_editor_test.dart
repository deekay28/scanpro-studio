import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/features/pdf_editor/engine/pdf_edit_engine.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/text_layout.dart';
import 'package:scanpro_studio/features/pdf_editor/model/edit_state.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

// ---------------------------------------------------------------------------
// Fixtures: real PDF files built with three different producers (a raw
// hand-written file, Syncfusion and PDFium itself).
// ---------------------------------------------------------------------------

final freeSans = File('assets/fonts/FreeSans.ttf').readAsBytesSync();

/// A minimal PDF as many generators write it: unembedded Helvetica with a
/// 1-pt font scaled by the text matrix.
Uint8List rawPdf() {
  const content = 'BT /F1 1 Tf 14 0 0 14 72 720 Tm (Invoice number 1042) Tj ET\n'
      'BT /F1 1 Tf 10 0 0 10 72 690 Tm (Thank you for your bussiness.) Tj ET\n';
  final objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n${content}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  ];
  final sb = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(sb.length);
    sb.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = sb.length;
  sb.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    sb.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(sb.toString().codeUnits);
}

Uint8List sfDoc(void Function(sf.PdfDocument d) build) {
  final d = sf.PdfDocument();
  d.pageSettings.margins.all = 0;
  build(d);
  final b = Uint8List.fromList(d.saveSync());
  d.dispose();
  return b;
}

String sfText(Uint8List bytes, {String? password, int? page}) {
  final d = password == null ? sf.PdfDocument(inputBytes: bytes) : sf.PdfDocument(inputBytes: bytes, password: password);
  try {
    final ex = sf.PdfTextExtractor(d);
    return page == null ? ex.extractText() : ex.extractText(startPageIndex: page, endPageIndex: page);
  } finally {
    d.dispose();
  }
}

Uint8List jpegBytes(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(30, 120, 200));
  return Uint8List.fromList(img.encodeJpg(im));
}

Uint8List pngWithAlpha(int w, int h) {
  final im = img.Image(width: w, height: h, numChannels: 4);
  for (final px in im) {
    final inside = (px.x - w / 2).abs() < w / 4;
    px
      ..r = 10
      ..g = 20
      ..b = 120
      ..a = inside ? 255 : 0;
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// Text as a standard PDF viewer extracts it (Poppler's pdftotext, the
/// engine behind many Linux viewers). Syncfusion's extractor cannot read
/// some valid ToUnicode maps, so it is not used for written Unicode text.
String viewerText(Uint8List bytes) {
  final f = File('${Directory.systemTemp.path}/viewer_${DateTime.now().microsecondsSinceEpoch}.pdf')..writeAsBytesSync(bytes);
  try {
    final r = Process.runSync('pdftotext', ['-enc', 'UTF-8', f.path, '-']);
    if (r.exitCode != 0) throw StateError('pdftotext failed: ${r.stderr}');
    return r.stdout as String;
  } finally {
    f.deleteSync();
  }
}

String findPdfium() {
  for (final root in ['build/native_assets', '.dart_tool/hooks_runner']) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('libpdfium.so') && f.path.contains('linux')) return f.path;
    }
  }
  throw StateError('libpdfium.so not found; run `flutter test` once so the pdfium_dart build hook downloads it.');
}

late PdfiumEngine engine;
late Directory draft;

TextBlockInfo blockContaining(PageAnalysis a, String s) => a.blocks.firstWhere((b) => b.text.contains(s), orElse: () => throw StateError('No block with "$s": ${a.blocks.map((b) => b.text).toList()}'));

void main() {
  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    engine = PdfiumEngine(unicodeFont: freeSans);
    draft = Directory.systemTemp.createTempSync('pdfeditor');
    File('${draft.path}/photo.jpg').writeAsBytesSync(jpegBytes(300, 400));
    File('${draft.path}/sig.png').writeAsBytesSync(pngWithAlpha(200, 80));
  });
  tearDownAll(() => draft.deleteSync(recursive: true));

  group('text layout', () {
    double m(String s) => s.length * 5.0;
    test('wraps, aligns and justifies', () {
      final r = layoutText('aaaa bbbb cccc dddd', 50, TextAlign2.left, m);
      expect(r.lineCount, 2);
      expect(r.runs.map((e) => e.text), ['aaaa bbbb', 'cccc dddd']);
      final c = layoutText('ab', 50, TextAlign2.center, m);
      expect(c.runs.single.x, 20);
      final j = layoutText('aa bb cc dd ee ff', 50, TextAlign2.justify, m);
      expect(j.runs.where((e) => e.line == 0).last.x + 10, closeTo(50, 0.001));
      expect(layoutText('one\n\ntwo', 100, TextAlign2.left, m).lineCount, 3);
    });
  });

  group('edit state', () {
    test('JSON round trip and undo/redo', () {
      var s = EditState.initial(3);
      final h = EditHistory(s);
      s = s.withItem(EditItem(id: 'a', slot: 'p0', kind: ItemKind.text, box: const Rect.fromLTWH(1, 2, 3, 4), text: 'Hi'));
      h.push(s);
      s = s.withTextEdit(const TextBlockEdit(page: 1, objects: [3, 4], text: 'X', style: TextStyleSpec(size: 9)));
      h.push(s);
      s = s.copyWith(slots: [s.slots[2], s.slots[0]]);
      h.push(s);
      final j = EditState.fromJson(s.toJson());
      expect(j.items.single.text, 'Hi');
      expect(j.textEdits.values.single.style!.size, 9);
      expect(j.slots.map((e) => e.id), ['p2', 'p0']);
      expect(h.undo().slots.length, 3);
      expect(h.undo().textEdits, isEmpty);
      expect(h.redo().textEdits.length, 1);
      expect(h.canRedo, isTrue);
    });
  });

  group('ACCEPTANCE (PDFium engine)', () {
    test('1. digitally generated PDF (unembedded Helvetica, scaled text matrix): fix a typo in place', () {
      final src = rawPdf();
      final digest = sha256.convert(src).toString();
      final s = engine.open(src);
      final a = s.analyze(0);
      final b = blockContaining(a, 'bussiness');
      expect(b.first.size, closeTo(10, 0.01), reason: 'Tf 1 scaled by Tm 10');
      expect(b.first.font.family, 'Helvetica');
      expect(b.first.font.embedded, isFalse);
      final edit = TextBlockEdit(page: 0, objects: b.objects, text: 'Thank you for your business.');
      final report = s.previewTextEdit(edit);
      expect(report.inPlace, isTrue);
      expect(report.originalFontUsed, isTrue);
      final out = s.export(EditState.initial(1).withTextEdit(edit));
      final text = sfText(out.bytes);
      expect(text, contains('Thank you for your business.'));
      expect(text, contains('Invoice number 1042'), reason: 'unrelated text untouched');
      // Position and size are kept.
      final s2 = engine.open(out.bytes);
      final b2 = blockContaining(s2.analyze(0), 'business');
      expect(b2.first.baseline.dx, closeTo(b.first.baseline.dx, 0.01));
      expect(b2.first.baseline.dy, closeTo(b.first.baseline.dy, 0.01));
      expect(b2.first.size, closeTo(10, 0.01));
      s2.close();
      s.close();
      expect(sha256.convert(src).toString(), digest, reason: 'original bytes unchanged');
    });

    test('2. fully embedded TrueType font is reused for the edit', () {
      // Build a PDF whose text uses the complete embedded FreeSans font.
      final base = sfDoc((d) => d.pages.add());
      final s0 = engine.open(base);
      final withText = s0.export(EditState.initial(1).withItem(const EditItem(
          id: 't', slot: 'p0', kind: ItemKind.text, box: Rect.fromLTWH(50, 50, 400, 40), text: 'Ünïcödé façade', style: TextStyleSpec(font: FontChoice.unicodeSans, size: 16))));
      s0.close();
      final s = engine.open(withText.bytes);
      final b = blockContaining(s.analyze(0), 'façade');
      expect(b.first.font.embedded, isTrue);
      expect(b.first.font.subset, isFalse);
      final edit = TextBlockEdit(page: 0, objects: b.objects, text: 'Ünïcödé façade — Zürich ₹');
      final r = s.previewTextEdit(edit);
      expect(r.originalFontUsed, isTrue, reason: 'the full font has the new glyphs');
      final out = s.export(EditState.initial(1).withTextEdit(edit));
      expect(viewerText(out.bytes), allOf(contains('Zürich'), contains('₹')));
      s.close();
    });

    test('3. subset font: missing glyphs fall back with a warning; present glyphs keep the font', () {
      final src = sfDoc((d) {
        d.pages.add().graphics.drawString('Hello world', sf.PdfTrueTypeFont(freeSans, 14), bounds: const Rect.fromLTWH(40, 40, 400, 30));
      });
      final s = engine.open(src);
      final b = blockContaining(s.analyze(0), 'Hello');
      expect(b.first.font.embedded, isTrue);
      final same = TextBlockEdit(page: 0, objects: b.objects, text: 'Hello world world');
      final r1 = s.previewTextEdit(same);
      expect(r1.originalFontUsed, isTrue, reason: 'only glyphs already in the subset');
      final other = TextBlockEdit(page: 0, objects: b.objects, text: 'Quixotic jazz');
      final r2 = s.previewTextEdit(other);
      expect(r2.originalFontUsed, isFalse);
      expect(r2.warnings.join(' '), contains('characters'));
      final out = s.export(EditState.initial(1).withTextEdit(other));
      expect(sfText(out.bytes), contains('Quixotic jazz'));
      s.close();
    });

    test('4. mixed sizes and colours: separate blocks, editing one leaves the others alone', () {
      final src = sfDoc((d) {
        final g = d.pages.add().graphics;
        g.drawString('Big red title', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 24), brush: sf.PdfSolidBrush(sf.PdfColor(200, 0, 0)), bounds: const Rect.fromLTWH(40, 40, 500, 40));
        g.drawString('Small blue note', sf.PdfStandardFont(sf.PdfFontFamily.timesRoman, 9), brush: sf.PdfSolidBrush(sf.PdfColor(0, 0, 200)), bounds: const Rect.fromLTWH(40, 100, 500, 20));
        g.drawString('Body text in black', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 130, 500, 20));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      final title = blockContaining(a, 'Big red');
      final note = blockContaining(a, 'Small blue');
      expect(title.key, isNot(note.key));
      expect(title.first.color & 0xFFFFFF, 0xC80000);
      expect(note.first.color & 0xFFFFFF, 0x0000C8);
      expect(PdfiumSession.familyFor(note.first.font.family), FontChoice.times);
      // Change the note: new text, bigger, green, bold.
      final edit = TextBlockEdit(
          page: 0, objects: note.objects, text: 'Updated note', style: note.originalStyle.copyWith(size: 11, color: 0xFF00AA00, bold: true, font: FontChoice.times));
      final out = s.export(EditState.initial(1).withTextEdit(edit));
      final s2 = engine.open(out.bytes);
      final a2 = s2.analyze(0);
      final n2 = blockContaining(a2, 'Updated note');
      expect(n2.first.color & 0xFFFFFF, 0x00AA00);
      expect(n2.first.size, closeTo(11, 0.01));
      expect(n2.first.font.baseName, 'Times-Bold');
      final t2 = blockContaining(a2, 'Big red title');
      expect(t2.first.color & 0xFFFFFF, 0xC80000);
      expect(t2.first.size, closeTo(24, 0.1));
      expect(blockContaining(a2, 'Body text').first.baseline, blockContaining(a, 'Body text').first.baseline);
      expect(sfText(out.bytes), isNot(contains('Small blue')));
      s2.close();
      s.close();
    });

    test('5. scanned image-only page: detected, OCR text layer added, scan kept', () {
      final src = sfDoc((d) {
        final page = d.pages.add();
        page.graphics.drawImage(sf.PdfBitmap(jpegBytes(600, 800)), Rect.fromLTWH(0, 0, page.getClientSize().width, page.getClientSize().height));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      expect(a.looksScanned, isTrue);
      expect(a.blocks, isEmpty, reason: 'no fake editable text');
      final state = EditState.initial(1)
          .withItem(const EditItem(id: 'o1', slot: 'p0', kind: ItemKind.ocrText, box: Rect.fromLTWH(60, 80, 200, 14), text: 'Recognised line one'))
          .withItem(const EditItem(id: 'c1', slot: 'p0', kind: ItemKind.cover, box: Rect.fromLTWH(60, 120, 200, 16), color: 0xFFFFFFFF))
          .withItem(const EditItem(id: 't1', slot: 'p0', kind: ItemKind.text, box: Rect.fromLTWH(62, 120, 200, 16), text: 'Corrected line', style: TextStyleSpec(size: 11)));
      final out = s.export(state);
      expect(sfText(out.bytes), allOf(contains('Recognised line one'), contains('Corrected line')));
      final s2 = engine.open(out.bytes);
      final a2 = s2.analyze(0);
      expect(a2.images.length, a.images.length, reason: 'scan image preserved');
      expect(a2.images.first.pixelWidth, 600);
      expect(a2.hasOcrLayer, isTrue);
      s2.close();
      s.close();
    });

    test('6. Hindi and English: blocks are found; Devanagari edits warn about shaping', () {
      final src = sfDoc((d) {
        final g = d.pages.add().graphics;
        final f = sf.PdfTrueTypeFont(freeSans, 14);
        g.drawString('Name: Ravi Kumar', f, bounds: const Rect.fromLTWH(40, 40, 400, 24));
        g.drawString('नाम: रवि कुमार', f, bounds: const Rect.fromLTWH(40, 90, 400, 24));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      final en = blockContaining(a, 'Ravi');
      final out = s.export(EditState.initial(1).withTextEdit(TextBlockEdit(page: 0, objects: en.objects, text: 'Name: Ravi Sharma', style: en.originalStyle.copyWith(font: FontChoice.unicodeSans))));
      expect(viewerText(out.bytes), contains('Ravi Sharma'));
      final hiBlock = a.blocks.firstWhere((b) => b.text.runes.any((r) => r >= 0x900 && r <= 0x97f));
      final r = s.previewTextEdit(TextBlockEdit(page: 0, objects: hiBlock.objects, text: 'नाम: रवि शर्मा', style: hiBlock.originalStyle.copyWith(font: FontChoice.unicodeSans)));
      expect(r.warnings.join(' '), contains('Devanagari'));
      s.close();
    });

    test('7. multi-page with headers/footers: reorder, delete, rotate, insert blank, page numbers', () {
      final src = sfDoc((d) {
        for (var i = 1; i <= 5; i++) {
          final sec = d.sections!.add();
          sec.pageSettings.margins.all = 0;
          final g = sec.pages.add().graphics;
          final f = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 10);
          g.drawString('Header of report', f, bounds: const Rect.fromLTWH(40, 10, 300, 14));
          g.drawString('Body $i', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 14), bounds: const Rect.fromLTWH(40, 100, 300, 20));
          g.drawString('Page $i', f, bounds: const Rect.fromLTWH(40, 800, 300, 14));
        }
      });
      final s = engine.open(src);
      var st = EditState.initial(5);
      // Order: 3, 1, blank, 5 (pages 2 and 4 deleted), page 1 rotated.
      st = st.copyWith(slots: [st.slots[2], st.slots[0].rotated(90), const PageSlot(id: 'b1'), st.slots[4]]);
      st = st.copyWith(decorations: const Decorations(pageNumbers: true, pageNumberFormat: 'Sheet {n}/{total}'));
      final out = s.export(st);
      expect(out.pageCount, 4);
      expect(sfText(out.bytes, page: 0), allOf(contains('Body 3'), contains('Sheet 1/4')));
      expect(sfText(out.bytes, page: 1), allOf(contains('Body 1'), contains('Sheet 2/4')));
      expect(sfText(out.bytes, page: 2), contains('Sheet 3/4'));
      expect(sfText(out.bytes, page: 3), contains('Body 5'));
      final d = sf.PdfDocument(inputBytes: out.bytes);
      expect(d.pages[1].rotation, sf.PdfPageRotateAngle.rotateAngle90);
      expect(d.pages[0].rotation, sf.PdfPageRotateAngle.rotateAngle0);
      d.dispose();
      // Extract a subset.
      final ex = s.export(st, options: const ExportOptions(onlySlots: [3]));
      expect(ex.pageCount, 1);
      expect(sfText(ex.bytes), contains('Body 5'));
      s.close();
    });

    test('8. images, links and form fields survive editing; new image, signature and annotations are placed correctly', () {
      final src = sfDoc((d) {
        final page = d.pages.add();
        page.graphics.drawString('Contract terms', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 300, 20));
        page.graphics.drawImage(sf.PdfBitmap(jpegBytes(120, 80)), const Rect.fromLTWH(300, 300, 120, 80));
        page.annotations.add(sf.PdfUriAnnotation(bounds: const Rect.fromLTWH(40, 70, 100, 15), uri: 'https://example.org'));
        d.form.fields.add(sf.PdfTextBoxField(page, 'name', const Rect.fromLTWH(40, 400, 200, 20), text: 'Alice'));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      expect(a.annotations, 2);
      final b = blockContaining(a, 'Contract');
      var st = EditState.initial(1).withTextEdit(TextBlockEdit(page: 0, objects: b.objects, text: 'Contract terms (revised)'));
      st = st.withItem(const EditItem(id: 'img', slot: 'p0', kind: ItemKind.image, box: Rect.fromLTWH(50, 500, 150, 200), asset: 'photo.jpg'));
      st = st.withItem(const EditItem(id: 'sig', slot: 'p0', kind: ItemKind.image, role: ImageRole.signature, box: Rect.fromLTWH(350, 700, 100, 40), asset: 'sig.png'));
      st = st.withItem(const EditItem(id: 'hl', slot: 'p0', kind: ItemKind.highlight, box: Rect.fromLTWH(40, 40, 120, 16), color: 0xFFFFEB3B));
      st = st.withItem(EditItem(id: 'ink', slot: 'p0', kind: ItemKind.ink, box: const Rect.fromLTWH(100, 600, 50, 50), strokes: const [
        [Offset(100, 600), Offset(150, 650)]
      ]));
      st = st.withItem(const EditItem(id: 'st', slot: 'p0', kind: ItemKind.stamp, box: Rect.fromLTWH(400, 100, 140, 50), text: 'APPROVED', color: 0xFF2E7D32));
      st = st.withItem(const EditItem(id: 'nt', slot: 'p0', kind: ItemKind.note, box: Rect.fromLTWH(500, 40, 20, 20), text: 'Check clause 4'));
      // Move the existing image.
      final im = a.images.single;
      st = st.withImageEdit(ImageObjEdit(page: 0, object: im.object, box: im.bounds.shift(const Offset(0, 50))));
      final out = s.export(st, draftDir: draft.path);
      expect(out.warnings, isEmpty, reason: out.warnings.join('; '));
      expect(out.annotationsAfter, out.annotationsBefore, reason: 'link and form widget kept');
      final d = sf.PdfDocument(inputBytes: out.bytes);
      expect(d.form.fields.count, 1);
      expect((d.form.fields[0] as sf.PdfTextBoxField).text, 'Alice');
      d.dispose();
      final raw = String.fromCharCodes(out.bytes);
      for (final sub in ['Link', 'Widget', 'Highlight', 'Ink', 'Stamp', 'Text']) {
        expect(RegExp('/Subtype\\s*/$sub\\b').hasMatch(raw), isTrue, reason: '$sub annotation present (not flattened)');
      }
      expect(String.fromCharCodes(out.bytes), contains('/AP'), reason: 'appearance streams written');
      final s2 = engine.open(out.bytes);
      final a2 = s2.analyze(0);
      expect(a2.annotations, 2 + 4, reason: 'link, widget + highlight, ink, stamp, note');
      final imgs = a2.images;
      final moved = imgs.firstWhere((i) => i.pixelWidth == 120);
      expect(moved.bounds.top, closeTo(im.bounds.top + 50, 0.5));
      final photo = imgs.firstWhere((i) => i.pixelWidth == 300);
      expect(photo.bounds.left, closeTo(50, 0.5));
      expect(photo.bounds.top, closeTo(500, 0.5));
      expect(photo.bounds.width, closeTo(150, 0.5));
      final sig = imgs.firstWhere((i) => i.pixelWidth == 200);
      expect(sig.bounds.top, closeTo(700, 0.5));
      // The stamp appearance is visible where it was placed (green pixels).
      final r = s2.render(EditState.initial(1), 'p0', 1);
      var green = 0;
      for (var y = 100; y < 150; y++) {
        for (var x = 400; x < 540; x++) {
          final i = (y * r.width + x) * 4;
          if (r.rgba[i + 1] > 90 && r.rgba[i] < 90) green++;
        }
      }
      expect(green, greaterThan(50));
      // Flattening on request removes the annotations into page content.
      final flat = s.export(st, draftDir: draft.path, options: const ExportOptions(flattenAnnotations: true));
      final s3 = engine.open(flat.bytes);
      expect(s3.analyze(0).annotations, lessThan(6));
      expect(viewerText(flat.bytes), contains('APPROVED'), reason: 'stamp burned into the page');
      s3.close();
      s2.close();
      s.close();
    });

    test('9. password-protected PDF: password required, encryption kept on export', () {
      final src = sfDoc((d) {
        d.pages.add().graphics.drawString('Secret memo', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12), bounds: const Rect.fromLTWH(40, 40, 300, 20));
        d.security
          ..algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit
          ..userPassword = 'pw123'
          ..ownerPassword = 'pw123';
      });
      expect(() => engine.open(src), throwsA(isA<EditorPasswordRequired>()));
      expect(() => engine.open(src, password: 'nope'), throwsA(isA<EditorPasswordRequired>().having((e) => e.wrong, 'wrong', true)));
      final s = engine.open(src, password: 'pw123');
      expect(s.encrypted, isTrue);
      final b = blockContaining(s.analyze(0), 'Secret');
      final out = s.export(EditState.initial(1).withTextEdit(TextBlockEdit(page: 0, objects: b.objects, text: 'Secret memo v2')));
      expect(out.encrypted, isTrue);
      expect(() => engine.open(out.bytes), throwsA(isA<EditorPasswordRequired>()));
      expect(sfText(out.bytes, password: 'pw123'), contains('Secret memo v2'));
      s.close();
    });

    test('10. large PDF (300 pages): edit one page, export and validate', () {
      final src = sfDoc((d) {
        final f = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12);
        for (var i = 0; i < 300; i++) {
          d.pages.add().graphics.drawString('Page body number $i', f, bounds: const Rect.fromLTWH(40, 40, 300, 20));
        }
      });
      final sw = Stopwatch()..start();
      final s = engine.open(src);
      expect(s.pageCount, 300);
      final b = blockContaining(s.analyze(150), 'number 150');
      final out = s.export(EditState.initial(300).withTextEdit(TextBlockEdit(page: 150, objects: b.objects, text: 'Page body number 150 (edited)')));
      expect(out.pageCount, 300);
      expect(sfText(out.bytes, page: 150), contains('(edited)'));
      expect(sfText(out.bytes, page: 151), contains('number 151'));
      final px = s.render(EditState.initial(300), 'p299', 1);
      expect(px.width, greaterThan(500));
      s.close();
      expect(sw.elapsed.inSeconds, lessThan(60));
    });

    test('moving a line keeps it on one line at the same relative baseline; style-only change keeps line breaks', () {
      final src = sfDoc((d) {
        final g = d.pages.add().graphics;
        final f = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12);
        g.drawString('A heading that must stay on one line', f, bounds: const Rect.fromLTWH(60, 60, 400, 16));
        g.drawString('Para line one is here and is long', f, bounds: const Rect.fromLTWH(60, 120, 400, 16));
        g.drawString('para line two is also here ok', f, bounds: const Rect.fromLTWH(60, 136, 400, 16));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      final h = blockContaining(a, 'heading');
      final moved = h.bounds.shift(const Offset(30, 200));
      final out = s.export(EditState.initial(1).withTextEdit(TextBlockEdit(page: 0, objects: h.objects, text: h.text, box: moved)));
      final s2 = engine.open(out.bytes);
      final h2 = blockContaining(s2.analyze(0), 'heading');
      expect(h2.lines.length, 1);
      expect(h2.first.baseline.dy - moved.top, closeTo(h.first.baseline.dy - h.bounds.top, 0.05));
      expect(h2.first.baseline.dx, closeTo(moved.left, 0.6));
      s2.close();
      final para = blockContaining(a, 'Para line one');
      expect(para.lines.length, 2);
      final out2 = s.export(EditState.initial(1).withTextEdit(
          TextBlockEdit(page: 0, objects: para.objects, text: para.text, style: para.originalStyle.copyWith(color: 0xFFC62828, font: FontChoice.helvetica))));
      final s3 = engine.open(out2.bytes);
      final p3 = blockContaining(s3.analyze(0), 'Para line one');
      expect(p3.lines.length, 2, reason: 'no unexpected wrapping');
      expect(p3.text, para.text);
      expect(p3.first.color & 0xFFFFFF, 0xC62828);
      s3.close();
      s.close();
    });

    test('added text is real selectable text; paragraph reflow keeps it inside the page', () {
      final src = sfDoc((d) {
        final g = d.pages.add().graphics;
        final f = sf.PdfStandardFont(sf.PdfFontFamily.timesRoman, 11);
        g.drawString('First line of the paragraph here', f, bounds: const Rect.fromLTWH(60, 100, 400, 14));
        g.drawString('second line of the paragraph here', f, bounds: const Rect.fromLTWH(60, 114, 400, 14));
        g.drawString('third and final line of it.', f, bounds: const Rect.fromLTWH(60, 128, 400, 14));
      });
      final s = engine.open(src);
      final a = s.analyze(0);
      final para = blockContaining(a, 'First line');
      expect(para.lines.length, 3, reason: 'three lines grouped into one paragraph');
      final longer = '${para.flowText} With an extra sentence appended to the paragraph to force wrapping.';
      final e = TextBlockEdit(page: 0, objects: para.objects, text: longer, style: para.originalStyle.copyWith(align: TextAlign2.left), box: para.bounds);
      final rep = s.previewTextEdit(e);
      expect(rep.outBounds.width, lessThanOrEqualTo(para.bounds.width + para.first.size * 0.6 + 0.5), reason: "wraps within the width plus the advance-width slack");
      expect(rep.fontUsed, contains('Times'));
      final shrink = s.previewTextEdit(e.copyWith(shrinkToFit: true));
      expect(shrink.outBounds.height, lessThanOrEqualTo(para.bounds.height + 1));
      final st = EditState.initial(1)
          .withTextEdit(e)
          .withItem(const EditItem(id: 'n', slot: 'p0', kind: ItemKind.text, box: Rect.fromLTWH(60, 300, 300, 40), text: 'Ref no. 2024/117', rotation: 0));
      final out = s.export(st);
      final t = sfText(out.bytes);
      expect(t, contains('Ref no. 2024/117'));
      expect(t.replaceAll(RegExp(r'\s+'), ' '), contains('force wrapping.'));
      s.close();
    });
  });
}
