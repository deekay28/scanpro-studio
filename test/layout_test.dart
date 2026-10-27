import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/features/convert/layout/layout_docx.dart';
import 'package:scanpro_studio/features/convert/layout/layout_model.dart';
import 'package:scanpro_studio/features/convert/layout/scan_analysis.dart';
import 'package:scanpro_studio/features/convert/model/page_content.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';

import 'convert_support.dart';
import 'pdf_editor_test.dart' show findPdfium, freeSans;

late PdfiumEngine engine;

/// Output folder for converted files and comparison reports. Set
/// SCANPRO_REPORT_DIR to keep them (e.g. test/fixtures/mess_bill/report).
final outDir = Directory(Platform.environment['SCANPRO_REPORT_DIR'] ?? '${Directory.systemTemp.path}/scanpro_layout')..createSync(recursive: true);

Map<String, dynamic> visualCompare(String sourcePdf, Uint8List docx, String label) {
  final f = File('${outDir.path}/$label.docx')..writeAsBytesSync(docx);
  final r = Process.runSync('python3', ['-I', 'test/tools/visual_compare.py', sourcePdf, f.path, outDir.path, label]);
  if (r.exitCode != 0) throw StateError('visual comparison failed: ${r.stderr}');
  return jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
}

List<PdfWord> ocrWords(Uint8List png) => [
      for (final (t, l, top, w, h, c) in tesseractWords(png)!) PdfWord(t, Rect.fromLTWH(l, top, w, h), confidence: c),
    ];

/// Converts page [i] of [s] the way the app does for a scanned page.
LayoutPage editableScan(PdfiumSession s, int i) {
  final size = s.pageSize(i);
  final img = s.pageImage(i, allowOriginal: true);
  // Render at the photo's own resolution and keep only the photo's area.
  final scale = img.original ? img.width / img.box.width : 200 / 72;
  final r = s.renderOriginal(i, scale);
  final (rgba, w, h) = cropRgba(r.rgba, r.width, r.height, Rect.fromLTRB(img.box.left * scale, img.box.top * scale, img.box.right * scale, img.box.bottom * scale));
  final prep = prepareScan(rgba, w, h, img.box);
  return buildScanLayout(prep, ocrWords(prep.png), size, debug: (n, png) => png.isEmpty ? print('DBG $n') : File('${outDir.path}/debug_$n.png').writeAsBytesSync(png));
}

LayoutPage faithful(PdfiumSession s, int i) {
  final im = s.pageImage(i);
  return LayoutPage(im.pageSize, background: LGraphic(im.box, im.bytes, im.ext, im.width, im.height, kind: GraphicKind.pageImage));
}

void main() {
  const source = 'test/fixtures/mess_bill/source.pdf';
  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    engine = PdfiumEngine(unicodeFont: freeSans);
  });

  final tools = hasLibreOffice && hasTesseract;

  test('MESS BILL A: faithful layout keeps the page exactly (original JPEG, one page, same size)', () {
    final s = engine.open(File(source).readAsBytesSync()) as PdfiumSession;
    final im = s.pageImage(0);
    expect(im.original, isTrue, reason: 'the scan JPEG is reused without recompression');
    final docx = writeLayoutDocx([faithful(s, 0)], title: 'Mess bill');
    s.close();
    if (!tools) return markTestSkipped('LibreOffice/tesseract not installed');
    final r = visualCompare(source, docx, 'faithful');
    expect(r['page_count_match'], isTrue);
    expect(r['page_size_match'], isTrue);
    final p = (r['pages'] as List).single as Map<String, dynamic>;
    expect(p['ssim'], greaterThan(0.95));
    expect(p['displacement_pt_median'], lessThan(2));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('MESS BILL B: editable document rebuilds text, table, shading and graphics in place', () {
    if (!hasTesseract) return markTestSkipped('tesseract not installed');
    final s = engine.open(File(source).readAsBytesSync()) as PdfiumSession;
    final page = editableScan(s, 0);
    s.close();
    final docx = writeLayoutDocx([page], title: 'Mess bill');
    File('${outDir.path}/editable_words.txt').writeAsStringSync([for (final l in page.lines) for (final w in l.words) '${w.box.left.toStringAsFixed(1)}\t${l.baseline.toStringAsFixed(1)}\t${w.size}\t${w.text}'].join('\n'));
    File('${outDir.path}/editable_lines.txt').writeAsStringSync([for (final l in page.lines) '${l.baseline.toStringAsFixed(1)}\t${l.box.left.toStringAsFixed(1)}\t${l.text}'].join('\n'));
    // ignore: avoid_print
    print([
      'lines: ${page.lines.map((l) => '${l.size}${l.words.any((w) => w.bold) ? 'b' : ''}:${l.text}').join(' | ')}',
      'tables: ${page.tables.map((t) => '${t.rows}x${t.columns} ${t.cells.map((c) => '[${c.row},${c.col} ${c.rowSpan}x${c.colSpan} ${c.lines.map((l) => l.text).join('/')}]').join(' ')}').join('; ')}',
      'shades: ${page.shades.map((x) => '${x.box} ${x.color.toRadixString(16)}').join(', ')}',
      'graphics: ${page.graphics.map((g) => '${g.kind.name} ${g.box}').join(', ')}',
      'warnings: ${page.warnings}',
    ].join('\n'));
    if (!tools) return;
    final r = visualCompare(source, docx, 'editable');
    // ignore: avoid_print
    print(File('${outDir.path}/editable_report.md').readAsStringSync());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
