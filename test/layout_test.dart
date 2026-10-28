import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:scanpro_studio/features/convert/conversion_service.dart';
import 'package:scanpro_studio/features/convert/layout/layout_docx.dart';
import 'package:scanpro_studio/features/convert/layout/layout_model.dart';
import 'package:scanpro_studio/features/convert/layout/ocr_review.dart';
import 'package:scanpro_studio/features/convert/model/doc_model.dart' show xmlEscape;
import 'package:scanpro_studio/features/convert/layout/scan_analysis.dart';
import 'package:scanpro_studio/features/convert/model/page_content.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'conversion_test.dart' show reportPdf;
import 'convert_support.dart';
import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc;

/// Regression tests for PDF → Word with the photographed MCTE MHOW mess
/// bill (test/fixtures/mess_bill/source.pdf) and generated documents.
///
/// Outputs are rendered with LibreOffice and compared with the source by
/// test/tools/visual_compare.py (side-by-side image, difference heatmap,
/// SSIM, OCR word positions). Set SCANPRO_REPORT_DIR to keep the files,
/// e.g. SCANPRO_REPORT_DIR=test/fixtures/mess_bill/report.
final outDir = Directory(Platform.environment['SCANPRO_REPORT_DIR'] ?? '${Directory.systemTemp.path}/scanpro_layout')..createSync(recursive: true);
const messBill = 'test/fixtures/mess_bill/source.pdf';

/// Tesseract stands in for ML Kit (Android only) as the OCR engine.
Future<List<PdfWord>> tesseractOcr(Uint8List png, int w, int h, String script) async =>
    tesseractPdfWords(png, lang: script == 'devanagari' && hasHindiOcr ? 'hin+eng' : 'eng')!;

bool get hasHindiOcr => (Process.runSync('tesseract', ['--list-langs']).stdout as String).contains('hin');

/// OCR engines report the same words with very different boxes. These
/// variants of the tesseract result imitate them: ML Kit's padded element
/// boxes (looser and very loose), and whole lines boxed and split evenly into
/// words (what the plugin falls back to without element boxes), all with
/// confident scores (so text OCR reads on stamps is not filtered by
/// confidence). The rebuilt page must not depend on which one is used.
OcrRecognizer variantOcr(String variant) => (png, w, h, script) async {
      final words = tesseractPdfWords(png)!;
      switch (variant) {
        case 'split':
          final lines = <int, List<PdfWord>>{};
          for (final x in words) {
            (lines[x.line!] ??= []).add(x);
          }
          final out = <PdfWord>[];
          for (final ws in lines.values) {
            final box = ws.map((x) => x.box).reduce((a, b) => a.expandToInclude(b));
            final chars = ws.fold<int>(0, (n, x) => n + x.text.length) + ws.length - 1;
            final per = box.width / chars;
            var x0 = box.left;
            for (final x in ws) {
              out.add(PdfWord(x.text, Rect.fromLTRB(x0, box.top, x0 + per * x.text.length, box.bottom), confidence: 0.8, line: x.line));
              x0 += per * (x.text.length + 1);
            }
          }
          return out;
        case 'mlkit':
          // What ML Kit did on the phone (v1.0.11, Scan 2026-10-28-1.docx):
          // looser boxes, lone ":" and "/" not returned, "Fac/Wing:" read
          // as "FacWing:", the lone "1" in the table not returned.
          return [
            for (final x in words)
              if (!RegExp(r'^[:/|]+$').hasMatch(x.text) && x.text != '1')
                PdfWord(x.text.replaceAll('/', x.text.length > 2 ? '' : '/'), x.box.inflate(x.box.height * 0.2), confidence: 0.75 + x.confidence! * 0.25, line: x.line),
          ];
        default:
          final pad = double.parse(variant.substring(3));
          return [for (final x in words) PdfWord(x.text, x.box.inflate(x.box.height * pad), confidence: 0.75 + x.confidence! * 0.25, line: x.line)];
      }
    };

/// Pictures in a DOCX wider than [share] of the page: strips cut from the
/// photo across text (the v1.0.10 failure).
int stripPictures(String xml, double pageWidthPt, {double share = 0.6}) => RegExp(r'<wp:extent cx="(\d+)" cy="(\d+)"/>')
    .allMatches(xml)
    .where((m) => int.parse(m[1]!) / 12700 > pageWidthPt * share && int.parse(m[2]!) / 12700 < 120)
    .length;

Map<String, dynamic> visualCompare(String sourcePdf, String docxPath, String label) {
  final r = Process.runSync('python3', ['-I', 'test/tools/visual_compare.py', sourcePdf, docxPath, outDir.path, label]);
  if (r.exitCode != 0) throw StateError('visual comparison failed: ${r.stderr}');
  return jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
}

void main() {
  late ConversionService service;
  late Directory work;
  final tools = hasLibreOffice && hasTesseract;

  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    service = ConversionService(unicodeFont: freeSans, ocr: tesseractOcr);
    work = Directory.systemTemp.createTempSync('layout');
  });
  tearDownAll(() => work.deleteSync(recursive: true));

  Future<(String, List<String>)> convert(String pdf, DocxMode mode, String label) async {
    final dir = Directory(p.join(work.path, label))..createSync();
    final r = await service.run(ConversionType.pdfToDocx, [(pdf, p.basename(pdf), null)], ConversionOptions(docxMode: mode), dir.path, label);
    final docx = r.outputs.single.path;
    File(docx).copySync(p.join(outDir.path, '$label.docx'));
    if (File(reviewPathFor(docx)).existsSync()) File(reviewPathFor(docx)).copySync(p.join(outDir.path, '$label.review.json'));
    File(p.join(outDir.path, '$label.notes.txt')).writeAsStringSync(r.warnings.join('\n'));
    return (docx, r.warnings);
  }

  Map<String, dynamic> page1(Map<String, dynamic> r) => (r['pages'] as List).first as Map<String, dynamic>;

  // ---------------------------------------------------------------------------
  // The reference document
  // ---------------------------------------------------------------------------

  test('TEST A (mess bill): faithful layout = the original page, unchanged', () async {
    final (docx, notes) = await convert(messBill, DocxMode.faithful, 'messbill_faithful');
    // The scan's own JPEG is embedded byte for byte (no recompression).
    final media = officeMedia(docx);
    expect(media.length, 1);
    expect(_same(media.values.single, File('test/fixtures/mess_bill/source_image.jpg').readAsBytesSync()), isTrue);
    expect(notes.join(' '), contains('cannot be edited'));
    if (!tools) return markTestSkipped('LibreOffice/tesseract not installed');
    final r = visualCompare(messBill, docx, 'messbill_faithful');
    expect(r['page_count_match'], isTrue, reason: 'one PDF page → one Word page');
    expect(r['page_size_match'], isTrue, reason: 'same page size and orientation');
    final pg = page1(r);
    expect(pg['ssim'], greaterThan(0.97));
    expect(pg['mean_abs_diff'], lessThan(3));
    expect(pg['displacement_pt_p90'], lessThan(1.5));
    expect(pg['word_recall'], greaterThan(0.95), reason: 'all text visible');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('TEST B (mess bill): editable document rebuilds text, table, band and graphics in place', () async {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    final (docx, notes) = await convert(messBill, DocxMode.editable, 'messbill_editable');
    final s = officeSummary(File(docx).readAsBytesSync(), 'docx');
    final text = '${(s['paragraphs'] as List).join('\n')}\n${jsonEncode(s['tables'])}';
    // Wording and values exactly as on the bill.
    for (final t in [
      'MCTE MHOW',
      "HEADQUARTERS OFFICERS' MESS BILL",
      'ACCOMMODATION CHARGES',
      'Oct-26',
      'Dhanjit Kumar Singh',
      'Basic Cyber Security-09',
      'FCT&S',
      '28-Jun-2026',
      '17-Oct-2026',
      'Seal/Stamp',
      'Mess Secretary',
      'Credit /Debit Card through POS',
      'QR Code',
    ]) {
      expect(text, contains(t), reason: t);
    }
    // The charges table: a real Word table with its rows, merged cells,
    // right-aligned amounts and the total in its own row.
    final tables = (s['tables'] as List).cast<List>();
    final table = tables.firstWhere((t) => t.any((r) => (r as List).join(' ').contains('Room Type')));
    expect(table.length, 3, reason: 'header, charges row, total row');
    expect((table[0] as List).join('|'), allOf(contains('Sr.'), contains('Room Type'), contains('Amount Payable')));
    expect((table[1] as List).join('|'), allOf(contains('Accommodation Charges'), contains('99,491.00')));
    expect((table[2] as List).join('|'), allOf(contains('Total Amount (Rounded off)'), contains('99,491.00')));
    final xml = officeXml(docx, 'word/document.xml');
    expect(xml, contains('<w:gridSpan w:val="3"/>'), reason: 'the total label spans the first columns');
    expect(xml, contains('<w:jc w:val="right"/>'), reason: 'amounts are right-aligned');
    // The shaded heading band, underlined heading.
    expect(RegExp(r'<w:shd w:val="clear" w:color="auto" w:fill="[0-9A-F]{6}"/>').hasMatch(xml), isTrue);
    expect(xml, contains('<w:u w:val="single"/>'));
    // QR code, seal and stamp/signature kept as pictures anchored on the page.
    expect(officeMedia(docx).length, greaterThanOrEqualTo(3));
    expect(xml, contains('descr="QR code"'));
    // The QR code still scans, to the same payload as on the photo.
    if (Process.runSync('which', ['zbarimg']).exitCode == 0) {
      String decode(Uint8List png) {
        final f = File(p.join(work.path, 'qr.png'))..writeAsBytesSync(png);
        return (Process.runSync('zbarimg', ['-q', '--raw', f.path]).stdout as String).trim();
      }

      final want = decode(File('test/fixtures/mess_bill/source_image.jpg').readAsBytesSync());
      expect(want, startsWith('upi://pay'));
      final qrRel = RegExp(r'descr="QR code"/>.*?r:embed="(rId\d+)"').firstMatch(xml)![1];
      final rels = officeXml(docx, 'word/_rels/document.xml.rels');
      final target = RegExp('Id="$qrRel"[^>]*Target="([^"]+)"').firstMatch(rels)![1];
      // Scanners need a quiet zone; add one around the crop as a printer would.
      final qr = img.decodePng(officeMedia(docx)['word/$target']!)!;
      final framed = img.Image(width: qr.width + 40, height: qr.height + 40)..clear(img.ColorRgb8(255, 255, 255));
      img.compositeImage(framed, qr, dstX: 20, dstY: 20);
      expect(decode(Uint8List.fromList(img.encodePng(img.copyResize(framed, width: framed.width * 3, interpolation: img.Interpolation.nearest)))), want);
    }
    expect(RegExp(r'<wp:anchor ').allMatches(xml).length, greaterThanOrEqualTo(3));
    // Editable text, not a page picture.
    expect((s['paragraphs'] as List).where((x) => (x as String).trim().isNotEmpty).length, greaterThan(10));
    expect(xml, isNot(contains('behindDoc="1"')));
    expect(notes.join(' '), contains('rebuilt as editable text'));
    if (!tools) return;
    final r = visualCompare(messBill, docx, 'messbill_editable');
    expect(r['page_count_match'], isTrue);
    expect(r['page_size_match'], isTrue);
    final pg = page1(r);
    expect(pg['word_recall'], greaterThan(0.85));
    expect(pg['displacement_pt_median'], lessThan(4), reason: 'text sits where it is on the bill');
    expect(pg['displacement_pt_p90'], lessThan(8));
    // Region coverage on the straightened photo: grey = text words,
    // red = ruling lines (table borders, underlines), green = shaded band,
    // blue = regions kept as pictures. Nothing is both text and picture.
    if (Platform.environment['SCANPRO_REPORT_DIR'] != null) {
      final s = PdfiumEngine(unicodeFont: freeSans).open(File(messBill).readAsBytesSync()) as PdfiumSession;
      final im = s.pageImage(0);
      final scale = im.width / im.box.width;
      final rr = s.renderOriginal(0, scale);
      s.close();
      final (rgba, w, h) = cropRgba(rr.rgba, rr.width, rr.height, Rect.fromLTRB(im.box.left * scale, im.box.top * scale, im.box.right * scale, im.box.bottom * scale));
      final prep = prepareScan(rgba, w, h, im.box);
      buildScanLayout(prep, tesseractPdfWords(prep.png)!, const Size(595.28, 841.89), debug: (n, png) {
        if (n == 'overlay') File(p.join(outDir.path, 'messbill_editable_coverage.png')).writeAsBytesSync(png);
      });
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('automatic mode keeps the scanned bill as a page image and says so', () async {
    final (docx, notes) = await convert(messBill, DocxMode.automatic, 'messbill_auto');
    expect(officeXml(docx, 'word/document.xml'), contains('behindDoc="1"'));
    expect(notes.join(' '), contains('Automatic'));
  });

  // ---------------------------------------------------------------------------
  // The phone failure (v1.0.10) and OCR engine independence
  // ---------------------------------------------------------------------------

  test('v1.0.10 phone output (fixture) had picture strips over text; every OCR box style now gives the same clean page', () async {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    // The phone's file: strips of the photo across the contact line, the
    // band and the bill details, with OCR text over them, and 6 pictures.
    final old = officeXml('test/fixtures/mess_bill/phone_v1.0.10/editable.docx', 'word/document.xml');
    expect(stripPictures(old, 595.3), 2, reason: 'the regression fixture shows the original failure');
    expect(RegExp('<wp:anchor ').allMatches(old).length, 6);
    for (final variant in ['pad0', 'pad0.2', 'pad0.5', 'split', 'mlkit']) {
      final svc = ConversionService(unicodeFont: freeSans, ocr: variantOcr(variant));
      final dir = Directory(p.join(work.path, 'v_$variant'))..createSync();
      final r = await svc.run(ConversionType.pdfToDocx, [(messBill, 'bill.pdf', null)], const ConversionOptions(docxMode: DocxMode.editable), dir.path, 'bill_$variant');
      final docx = r.outputs.single.path;
      File(docx).copySync(p.join(outDir.path, 'messbill_ocr_$variant.docx'));
      final xml = officeXml(docx, 'word/document.xml');
      final why = 'OCR variant $variant';
      // One region, one strategy: no strips, no page picture, no overlaps.
      expect(stripPictures(xml, 595.3), 0, reason: why);
      expect(xml, isNot(contains('behindDoc="1"')), reason: why);
      expect(xml, isNot(contains('w:highlight')), reason: '$why: a clean document by default');
      expect(r.warnings.where((w) => w.contains('check the layout')), isEmpty, reason: '$why: ${r.warnings}');
      // Exactly the three graphics, each once.
      final descr = RegExp(r'descr="([^"]*)"').allMatches(xml).map((m) => m[1]).toList();
      expect(descr.length, 3, reason: '$why: $descr');
      expect(descr.where((d) => d == 'QR code').length, 1, reason: why);
      // Text and tables.
      final s = officeSummary(File(docx).readAsBytesSync(), 'docx');
      final text = '${(s['paragraphs'] as List).join('\n')}\n${jsonEncode(s['tables'])}';
      for (final t in ['HEADQUARTERS', "OFFICERS'", 'ACCOMMODATION', 'CHARGES', 'Dhanjit Kumar Singh', 'Basic Cyber Security-09', 'FCT&S', '28-Jun-2026', '17-Oct-2026', 'Oct-26',
          'Accommodation Charges', 'Total Amount', 'Seal/Stamp', 'Mess Secretary', 'favour of', 'Machine at Reception', 'Payment also made']) {
        expect(text, contains(t), reason: '$why: $t');
      }
      expect(text.toUpperCase(), contains('MESS ACCOMMODATION'), reason: '$why: the band heading is complete');
      // Labels keep their colons and slashes even when OCR leaves them out
      // (read from the ink: two stacked dots, a rising stroke).
      final paras = (s['paragraphs'] as List).cast<String>().map((x) => x.replaceAll(RegExp(r'\s+'), ' ')).toList();
      for (final label in ['Rank', 'Name', 'Status', 'From', 'Date']) {
        expect(paras.any((x) => RegExp('$label ?:').hasMatch(x)), isTrue, reason: '$why: "$label :" in $paras');
      }
      expect(text, contains('Fac/Wing'), reason: why);
      expect(text, contains('Credit /Debit'), reason: why);
      if (variant == 'mlkit') {
        // The lone "1" OCR didn't return (and can't read from a crop) is
        // reported and listed for review, not silently lost.
        expect(r.warnings.join(' '), contains('could not be read'), reason: why);
        expect(File(reviewPathFor(docx)).readAsStringSync(), contains('unread mark in a table cell'), reason: why);
      }
      expect(paras.any((x) => RegExp('Bill ?No ?:').hasMatch(x)), isTrue, reason: '$why: $paras');
      expect(text, matches(RegExp(r"at par\S? / crossed")), reason: why);
      // The grey band lines up with the table below it.
      final bandTbl = RegExp(r'<w:tbl>.*?</w:tbl>').allMatches(xml).map((m) => m[0]!).toList();
      double edge(String t, {bool right = false}) {
        final ind = int.parse(RegExp(r'<w:tblInd w:w="(-?\d+)"').firstMatch(t)![1]!);
        final cols = RegExp(r'<w:gridCol w:w="(\d+)"').allMatches(t).map((m) => int.parse(m[1]!)).fold(0, (a, b) => a + b);
        return 14 + (right ? ind + cols : ind) / 20;
      }
      final band = bandTbl.firstWhere((t) => t.contains('ACCOMMODATION')), table = bandTbl.firstWhere((t) => t.contains('99,491.00'));
      expect(edge(band), closeTo(edge(table), 1.5), reason: '$why: band starts where the table starts');
      expect(edge(band, right: true), closeTo(edge(table, right: true), 1.5), reason: '$why: band ends where the table ends');
      final tables = (s['tables'] as List).cast<List>();
      final charges = tables.firstWhere((t) => jsonEncode(t).contains('99,491.00'));
      expect(charges.length, 3, reason: '$why: header, charges and total rows');
      expect('99,491.00'.allMatches(jsonEncode(charges)).length, 2, reason: why);
      if (variant != 'split') {
        // Evenly split line boxes can put header words one cell off.
        expect((charges[0] as List).join('|'), allOf(contains('Sr.'), contains('Room Type'), contains('Amount Payable')), reason: why);
      }
      if (!tools) continue;
      final v = visualCompare(messBill, docx, 'messbill_ocr_$variant');
      expect(v['page_count_match'], isTrue, reason: why);
      expect(page1(v)['word_recall'], greaterThan(0.8), reason: why);
      expect(page1(v)['displacement_pt_median'], lessThan(4), reason: why);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('OCR review: uncertain words are bookmarked, not highlighted, and corrections change only them', () async {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    final (docx, notes) = await convert(messBill, DocxMode.editable, 'messbill_review');
    final xml = officeXml(docx, 'word/document.xml');
    expect(xml, isNot(contains('w:highlight')));
    final review = File(reviewPathFor(docx));
    expect(review.existsSync(), isTrue, reason: 'tesseract reads some words of the photo with low confidence');
    final (items, pages) = decodeReview(review.readAsStringSync());
    final check = items.where((i) => !i.omitted).toList();
    expect(check, isNotEmpty);
    expect(pages.single.width, closeTo(595.3, 0.1));
    expect(notes.join(' '), contains('Review OCR words'));
    for (final i in check) {
      expect(xml, contains('w:name="_OCR_${i.id}"'));
    }
    // Correct the first one; the rest of the document is unchanged.
    final first = check.first;
    final fixed = applyOcrCorrections(File(docx).readAsBytesSync(), {first.id: 'CORRECTED'});
    final f2 = File(p.join(work.path, 'fixed.docx'))..writeAsBytesSync(fixed);
    final xml2 = officeXml(f2.path, 'word/document.xml');
    expect(xml2, contains('>CORRECTED<'));
    expect(xml2.replaceFirst('>CORRECTED<', '>${xmlEscape(first.text)}<'), xml);
    expect(officeMedia(f2.path).length, officeMedia(docx).length);
    // The review copy option still highlights.
    final dir = Directory(p.join(work.path, 'hl'))..createSync();
    final r = await service.run(ConversionType.pdfToDocx, [(messBill, 'bill.pdf', null)], const ConversionOptions(docxMode: DocxMode.editable, markUncertain: true), dir.path, 'hl');
    expect(officeXml(r.outputs.single.path, 'word/document.xml'), contains('w:highlight'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('editability: title, a detail, the amount cell, the QR position, the seal image and a note can be changed in place', () async {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    if (Process.runSync('python3', ['-c', 'import docx']).exitCode != 0) return markTestSkipped('python-docx not installed');
    final (docx, _) = await convert(messBill, DocxMode.editable, 'messbill_edit');
    final dir = Directory(p.join(outDir.path, 'edit_check'))..createSync(recursive: true);
    final r = Process.runSync('python3', ['-I', 'test/tools/edit_check.py', docx, dir.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final report = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
    final checks = (report['checks'] as Map).cast<String, dynamic>();
    for (final e in checks.entries) {
      expect((e.value as Map)['ok'], isTrue, reason: '${e.key}: ${(e.value as Map)['detail']}');
    }
    expect(checks.length, greaterThanOrEqualTo(11));
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ---------------------------------------------------------------------------
  // TEST C: general regression
  // ---------------------------------------------------------------------------

  test('TEST C4: Hindi and English, digital and scanned', () async {
    final pdf = sfDoc((d) {
      final g = d.pages.add().graphics;
      final f = sf.PdfTrueTypeFont(freeSans, 16);
      g.drawString('Name: Ravi Kumar', f, bounds: const Rect.fromLTWH(40, 40, 400, 28));
      g.drawString('नाम: रवि कुमार', f, bounds: const Rect.fromLTWH(40, 90, 400, 28));
      g.drawString('Amount: 1,250.00', f, bounds: const Rect.fromLTWH(40, 140, 400, 28));
    });
    final digital = File(p.join(work.path, 'hindi.pdf'))..writeAsBytesSync(pdf);
    final (docx, _) = await convert(digital.path, DocxMode.editable, 'hindi_digital');
    final text = (officeSummary(File(docx).readAsBytesSync(), 'docx')['paragraphs'] as List).join(' ');
    expect(text, allOf(contains('Ravi'), contains('1,250.00')));
    expect(text.runes.any((r) => r >= 0x900 && r <= 0x97f), isTrue, reason: 'Devanagari kept as text');
    if (!hasTesseract || !hasHindiOcr) return markTestSkipped('Hindi OCR data not installed');
    // A photographed Hindi + English form (test/fixtures/hindi: shaped
    // Devanagari, tilted, on a dark desk), read with the Devanagari model.
    final jpg = File('test/fixtures/hindi/hindi_english_scan.jpg').readAsBytesSync();
    final scan = File(p.join(work.path, 'hindi_scan.pdf'))
      ..writeAsBytesSync(sfDoc((d) {
        d.pageSettings.margins.all = 0;
        final pg = d.pages.add();
        pg.graphics.drawImage(sf.PdfBitmap(jpg), Rect.fromLTWH(0, 0, pg.getClientSize().width, pg.getClientSize().height));
      }));
    final dir = Directory(p.join(work.path, 'hin'))..createSync();
    final res = await service.run(ConversionType.pdfToDocx, [(scan.path, 'hindi_scan.pdf', null)], const ConversionOptions(docxMode: DocxMode.editable, ocrScript: 'devanagari'), dir.path, 'hindi_scan');
    File(res.outputs.single.path).copySync(p.join(outDir.path, 'hindi_scan.docx'));
    final st = (officeSummary(File(res.outputs.single.path).readAsBytesSync(), 'docx')['paragraphs'] as List).join(' ');
    // Tesseract's Hindi model drops the leading "1" of the amount; the
    // converter keeps what OCR read and never guesses digits.
    expect(st, allOf(contains('Ravi Kumar'), contains('Office Bill'), contains('Payment may be made'), contains('250.00')));
    for (final hi in ['नाम', 'रवि कुमार', 'मेजर', 'भुगतान']) {
      expect(st, contains(hi), reason: 'Devanagari read from the scan: $st');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('TEST C1: digital multi-page PDF with tables and an image → editable, same pages, text in place', () async {
    final pdf = File(p.join(work.path, 'report.pdf'))..writeAsBytesSync(reportPdf());
    final (docx, notes) = await convert(pdf.path, DocxMode.editable, 'report_editable');
    final s = officeSummary(File(docx).readAsBytesSync(), 'docx');
    final text = (s['paragraphs'] as List).join('\n');
    expect(text, allOf(contains('Annual Report 2024'), contains('Overview'), contains('Expanded into two new markets')));
    expect(jsonEncode(s['tables']), allOf(contains('Region'), contains('45,000.00')));
    expect(officeMedia(docx), isNotEmpty, reason: 'the embedded image is kept');
    expect(notes.join(' '), contains('digital page'));
    if (!hasLibreOffice) return;
    final r = visualCompare(pdf.path, docx, 'report_editable');
    expect(r['page_count_match'], isTrue);
    expect(r['page_size_match'], isTrue);
    for (final pg in (r['pages'] as List).cast<Map<String, dynamic>>()) {
      expect(pg['word_recall'], greaterThan(0.85));
      expect(pg['displacement_pt_median'], lessThan(3));
    }
    final (fdocx, _) = await convert(pdf.path, DocxMode.faithful, 'report_faithful');
    final f = visualCompare(pdf.path, fdocx, 'report_faithful');
    expect(f['page_count_match'], isTrue);
    expect(page1(f)['ssim'], greaterThan(0.95));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('TEST C2: skewed scan → editable text straightened; mixed document → automatic per page', () async {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    // A photo-like scan of page 1 of the report: rotated 3°, on a dark desk.
    final s = PdfiumEngine(unicodeFont: freeSans).open(reportPdf()) as PdfiumSession;
    final r = s.renderOriginal(0, 150 / 72);
    s.close();
    var page = img.Image.fromBytes(width: r.width, height: r.height, bytes: r.rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba).convert(numChannels: 3);
    page = img.copyRotate(page, angle: 3, interpolation: img.Interpolation.linear);
    final photo = img.Image(width: (page.width * 1.08).round(), height: (page.height * 1.06).round())..clear(img.ColorRgb8(45, 40, 38));
    img.compositeImage(photo, page, dstX: (photo.width - page.width) ~/ 2, dstY: (photo.height - page.height) ~/ 2);
    final jpg = Uint8List.fromList(img.encodeJpg(photo, quality: 88));
    final scan = sfDoc((d) {
      d.pageSettings.margins.all = 0;
      final pg = d.pages.add();
      pg.graphics.drawImage(sf.PdfBitmap(jpg), Rect.fromLTWH(0, 0, pg.getClientSize().width, pg.getClientSize().height));
    });
    final scanFile = File(p.join(work.path, 'skewed.pdf'))..writeAsBytesSync(scan);
    scanFile.copySync(p.join(outDir.path, 'skewed_source.pdf'));
    final (docx, _) = await convert(scanFile.path, DocxMode.editable, 'skewed_editable');
    if (tools) visualCompare(scanFile.path, docx, 'skewed_editable');
    final sum = officeSummary(File(docx).readAsBytesSync(), 'docx');
    final text = (sum['paragraphs'] as List).join(' ') + jsonEncode(sum['tables']);
    expect(text, allOf(contains('Annual Report 2024'), contains('Overview'), contains('Revenue increased')));
    expect(jsonEncode(sum['tables']), contains('Region'), reason: 'the ruled table is rebuilt from the scan');
    // Mixed: a digital page followed by the scan.
    final a = sf.PdfDocument(inputBytes: reportPdf()), b = sf.PdfDocument(inputBytes: scan);
    final mixed = sf.PdfDocument()..pageSettings.margins.all = 0;
    for (final src in [a.pages[0], b.pages[0]]) {
      final sec = mixed.sections!.add();
      sec.pageSettings.margins.all = 0;
      sec.pageSettings.size = src.size;
      sec.pages.add().graphics.drawPdfTemplate(src.createTemplate(), Offset.zero);
    }
    final mixedFile = File(p.join(work.path, 'mixed.pdf'))..writeAsBytesSync(mixed.saveSync());
    mixed.dispose();
    a.dispose();
    b.dispose();
    final (mdocx, notes) = await convert(mixedFile.path, DocxMode.automatic, 'mixed_auto');
    final xml = officeXml(mdocx, 'word/document.xml');
    expect('behindDoc="1"'.allMatches(xml).length, 1, reason: 'only the scanned page is a page image');
    expect(xml, allOf(contains('>Overview<'), contains('>Region<'), contains('>45,000.00<')), reason: 'the digital page is real text');
    expect(notes.join(' '), allOf(contains('1 page(s) were kept as page images'), contains('1 digital page(s) rebuilt')));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('TEST C3: different page sizes and orientations map one-to-one in both modes', () async {
    final pdf = sfDoc((d) {
      d.pageSettings.margins.all = 0;
      for (final (size, label) in [(const Size(595.28, 841.89), 'A4 portrait'), (const Size(595.28, 419.53), 'A5 landscape'), (const Size(612, 792), 'Letter')]) {
        final sec = d.sections!.add();
        sec.pageSettings.margins.all = 0;
        sec.pageSettings.size = size;
        if (size.width > size.height) sec.pageSettings.orientation = sf.PdfPageOrientation.landscape;
        sec.pages.add().graphics.drawString('Page in $label', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 18), bounds: const Rect.fromLTWH(50, 60, 400, 30));
      }
    });
    final f = File(p.join(work.path, 'sizes.pdf'))..writeAsBytesSync(pdf);
    for (final mode in [DocxMode.faithful, DocxMode.editable]) {
      final (docx, _) = await convert(f.path, mode, 'sizes_${mode.name}');
      final xml = officeXml(docx, 'word/document.xml');
      final sizes = RegExp(r'<w:pgSz w:w="(\d+)" w:h="(\d+)"').allMatches(xml).map((m) => (int.parse(m[1]!) / 20, int.parse(m[2]!) / 20)).toList();
      expect(sizes.length, 3, reason: mode.name);
      expect(sizes[0].$1, closeTo(595.3, 0.1));
      expect(sizes[1].$1, greaterThan(sizes[1].$2), reason: 'landscape kept');
      expect(sizes[2], (612.0, 792.0));
      if (!hasLibreOffice) continue;
      final r = visualCompare(f.path, docx, 'sizes_${mode.name}');
      expect(r['page_count_match'], isTrue, reason: mode.name);
      expect(r['page_size_match'], isTrue, reason: mode.name);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('layout helpers: font metrics, empty pages, flat scans', () {
    expect(textAdvance('HEADQUARTERS', bold: true) * 10, closeTo(84.4, 0.1));
    expect(fitSize('Hello', textAdvance('Hello') * 12), closeTo(12, 1e-9));
    expect(baselineRatio, 0.81);
    expect(writeLayoutDocx([LayoutPage(const Size(300, 200))]), isNotEmpty);
    expect(findPaperQuad(Uint8List(64 * 64)..fillRange(0, 64 * 64, 255), 64, 64), isNull, reason: 'no background: a flat scan');
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
