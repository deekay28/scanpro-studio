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
Future<List<PdfWord>> tesseractOcr(Uint8List png, int w, int h, String script) async => [
      for (final (t, l, top, ww, hh, c) in tesseractWords(png)!) PdfWord(t, Rect.fromLTWH(l, top, ww, hh), confidence: c),
    ];

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
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('automatic mode keeps the scanned bill as a page image and says so', () async {
    final (docx, notes) = await convert(messBill, DocxMode.automatic, 'messbill_auto');
    expect(officeXml(docx, 'word/document.xml'), contains('behindDoc="1"'));
    expect(notes.join(' '), contains('Automatic'));
  });

  // ---------------------------------------------------------------------------
  // TEST C: general regression
  // ---------------------------------------------------------------------------

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
