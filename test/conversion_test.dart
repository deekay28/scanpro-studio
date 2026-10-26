import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/features/convert/doc_to_pdf.dart';
import 'package:scanpro_studio/features/convert/model/doc_model.dart';
import 'package:scanpro_studio/features/convert/model/page_content.dart';
import 'package:scanpro_studio/features/convert/office_conversions.dart';
import 'package:scanpro_studio/features/convert/ooxml/docx.dart';
import 'package:scanpro_studio/features/convert/ooxml/pptx.dart';
import 'package:scanpro_studio/features/convert/ooxml/xlsx.dart';
import 'package:scanpro_studio/features/convert/pdf_to_doc.dart';
import 'package:scanpro_studio/features/convert/table_extraction.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'convert_support.dart';
import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc, viewerText;

/// A two-page report: title, headings, wrapped paragraph, bullets, a ruled
/// table, a borderless table, an image and a running header/footer.
Uint8List reportPdf() => sfDoc((d) {
      final helv = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 11);
      final bold = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 16, style: sf.PdfFontStyle.bold);
      final title = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 26, style: sf.PdfFontStyle.bold);
      final small = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 8);
      for (var p = 1; p <= 2; p++) {
        final page = d.pages.add();
        final g = page.graphics;
        g.drawString('ACME Corp - Annual Report', small, bounds: const Rect.fromLTWH(60, 15, 300, 10));
        g.drawString('Page $p of 2', small, bounds: const Rect.fromLTWH(60, 815, 300, 10));
        if (p == 1) {
          g.drawString('Annual Report 2024', title, bounds: const Rect.fromLTWH(60, 50, 480, 34));
          g.drawString('Overview', bold, bounds: const Rect.fromLTWH(60, 100, 480, 20));
          sf.PdfTextElement(
                  text: 'Revenue increased across all regions this year. The board approved a new strategy focused on '
                      'digital services, and operating costs fell for the third consecutive year.',
                  font: helv)
              .draw(page: page, bounds: const Rect.fromLTWH(60, 126, 470, 60));
          final uniBullet = sf.PdfTrueTypeFont(freeSans, 11);
          g.drawString('• Expanded into two new markets', uniBullet, bounds: const Rect.fromLTWH(60, 180, 470, 0));
          g.drawString('• Launched the mobile platform', uniBullet, bounds: const Rect.fromLTWH(60, 196, 470, 0));
          final grid = sf.PdfGrid();
          grid.columns.add(count: 3);
          grid.headers.add(1);
          grid.headers[0].cells[0].value = 'Region';
          grid.headers[0].cells[1].value = 'Units';
          grid.headers[0].cells[2].value = 'Revenue';
          for (final r in [
            ['North', '1,200', '45,000.00'],
            ['South', '950', '38,250.50'],
          ]) {
            final row = grid.rows.add();
            for (var i = 0; i < 3; i++) {
              row.cells[i].value = r[i];
            }
          }
          grid.style = sf.PdfGridStyle(font: helv);
          grid.draw(page: page, bounds: const Rect.fromLTWH(60, 230, 400, 0));
          final im = img.Image(width: 120, height: 60)..clear(img.ColorRgb8(20, 120, 200));
          g.drawImage(sf.PdfBitmap(Uint8List.fromList(img.encodePng(im))), const Rect.fromLTWH(60, 330, 120, 60));
        } else {
          g.drawString('Expenses', bold, bounds: const Rect.fromLTWH(60, 50, 480, 20));
          final rows = [
            ['Item', 'Date', 'Amount'],
            ['Paper', '01/03/2024', '₹1,200.50'],
            ['Toner', '15/03/2024', '₹3,450.00'],
            ['Repairs', '28/03/2024', '(500.00)'],
          ];
          final uni = sf.PdfTrueTypeFont(freeSans, 11);
          for (var r = 0; r < rows.length; r++) {
            for (var c = 0; c < 3; c++) {
              g.drawString(rows[r][c], uni, bounds: Rect.fromLTWH([60.0, 220.0, 380.0][c], 90.0 + r * 18, 150, 0));
            }
          }
        }
      }
    });

late PdfiumEngine engine;
PdfiumSession op(Uint8List b) => engine.open(b) as PdfiumSession;
List<PageContent> contentOf(Uint8List pdf) {
  final s = op(pdf);
  try {
    return [for (var i = 0; i < s.pageCount; i++) s.content(i)];
  } finally {
    s.close();
  }
}

void main() {
  late Directory fixtures;
  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    engine = PdfiumEngine(unicodeFont: freeSans);
    fixtures = Directory.systemTemp.createTempSync('fixtures');
    final r = Process.runSync('python3', ['-I', 'test/tools/make_office_fixtures.py', fixtures.path]);
    if (r.exitCode != 0) throw StateError('fixture generation failed: ${r.stderr}');
  });

  test('content extraction: words with style, lines, images, ruling lines', () {
    final pages = contentOf(reportPdf());
    expect(pages.length, 2);
    final p1 = pages[0];
    final title = p1.lines.firstWhere((l) => l.text.contains('Annual Report 2024'));
    expect(title.size, closeTo(26, 0.5));
    expect(title.bold, isTrue);
    expect(p1.images.single.pixelWidth, 120);
    expect(p1.rules.where((r) => r.horizontal).length, greaterThanOrEqualTo(3));
    expect(pages[1].lines.any((l) => l.text.contains('₹1,200.50')), isTrue);
  });

  test('table extraction: ruled grid and borderless columns with typed values', () {
    final pages = contentOf(reportPdf());
    final t1 = const TableExtractionService().extract(pages[0]);
    final ruled = t1.firstWhere((t) => t.method == 'ruled');
    expect(ruled.rows.map((r) => r.map((c) => c.text).toList()), [
      ['Region', 'Units', 'Revenue'],
      ['North', '1,200', '45,000.00'],
      ['South', '950', '38,250.50'],
    ]);
    expect(ruled.rows[2][2].number, 38250.5);
    expect(ruled.headerRow, isTrue);
    final t2 = const TableExtractionService().extract(pages[1]).single;
    expect(t2.method, 'aligned columns');
    expect(t2.rows.length, 4);
    expect(t2.rows[1][1].date, DateTime.utc(2024, 3, 1));
    expect(t2.rows[1][2].number, 1200.5);
    expect(t2.rows[3][2].number, -500, reason: 'accounting negative');
    expect(parseCell('8O0').uncertain, isTrue, reason: 'O/0 confusion flagged');
    expect(parseCell('12.5%').number, closeTo(0.125, 1e-9));
    expect(parseCell('1,234').number, 1234);
    expect(parseCell('03/04/24').date, isNull, reason: 'two-digit years are not guessed');
  });

  test('ACCEPTANCE 1: multi-page digital PDF → editable DOCX (and layout mode)', () {
    final pages = contentOf(reportPdf());
    final r = buildDoc(pages, title: 'Report');
    final bytes = writeDocx(r.doc);
    final s = officeSummary(bytes, 'docx');
    final paras = (s['paragraphs'] as List).cast<String>();
    expect(paras, contains('Annual Report 2024'));
    expect(s['styles'], containsAll(['Title', 'Heading 2', 'List Paragraph']));
    expect(paras.any((p) => p.startsWith('Revenue increased across all regions this year. The board approved')), isTrue, reason: 'wrapped lines rejoined');
    expect(paras, contains('Expanded into two new markets'));
    expect(paras.where((p) => p.contains('ACME Corp')), isEmpty, reason: 'running header removed from the body');
    expect(s['header'], 'ACME Corp - Annual Report');
    final tables = s['tables'] as List;
    expect(tables.length, 2);
    expect(tables[0][1], ['North', '1,200', '45,000.00']);
    expect(s['images'], greaterThanOrEqualTo(1));
    expect(s['bold_runs'], contains('Overview'));
    if (hasLibreOffice) {
      final pdf = libreOfficeToPdf(bytes, 'docx')!;
      expect(viewerText(pdf), contains('Revenue increased'));
    }
    final layout = buildDoc(pages, mode: WordMode.layout);
    final ls = officeSummary(writeDocx(layout.doc), 'docx');
    expect(ls['sections'], 2, reason: 'one section per page');
    expect((ls['paragraphs'] as List).cast<String>().any((p) => p.contains('Page 2 of 2')), isTrue);
  });

  test('ACCEPTANCE 2: PDF tables → XLSX and CSV', () {
    final pages = contentOf(reportPdf());
    final tables = [for (final p in pages) ...const TableExtractionService().extract(p)];
    final bytes = writeXlsx(tablesToSheets(tables));
    final s = officeSummary(bytes, 'xlsx')['sheets'] as Map<String, dynamic>;
    expect(s.keys, ['Page 1 table 1', 'Page 2 table 1']);
    final p1 = s['Page 1 table 1'] as List;
    expect(p1[0][0], startsWith('Source: page 1'));
    expect(p1[2], ['Region', 'Units', 'Revenue']);
    expect(p1[4], ['South', 950, 38250.5]);
    final p2 = s['Page 2 table 1'] as List;
    expect(p2[3][1], startsWith('2024-03-01'));
    expect(p2[5][2], -500);
    final perPage = officeSummary(writeXlsx(tablesToSheets(tables, perPage: true)), 'xlsx')['sheets'] as Map<String, dynamic>;
    expect(perPage.keys, ['Page 1', 'Page 2']);
    final csv = tableToCsv([for (final r in tables.last.rows) [for (final c in r) c.text]]);
    expect(csv.split('\r\n')[1], 'Paper,01/03/2024,"₹1,200.50"');
  });

  test('ACCEPTANCE 3: PDF → PPTX (visual and editable)', () {
    final pdf = reportPdf();
    final pages = contentOf(pdf);
    final s = op(pdf);
    final visual = PresentationModel([
      for (var i = 0; i < s.pageCount; i++)
        SlideModel([SlidePicture(Rect.fromLTWH(0, 0, 720, 720 * pages[i].size.height / pages[i].size.width), s.renderEncoded(i, dpi: 100, format: RasterFormat.jpg))])
    ], width: 720, height: 720 * pages[0].size.height / pages[0].size.width);
    s.close();
    final vs = officeSummary(writePptx(visual), 'pptx');
    expect((vs['slides'] as List).length, 2);
    expect(vs['slides'][0]['pictures'], 1);
    expect(vs['height'] / vs['width'], closeTo(842 / 595, 0.01), reason: 'page aspect ratio kept');
    final editable = pagesToEditableSlides(pages);
    final es = officeSummary(writePptx(editable.deck), 'pptx');
    final texts = (es['slides'][0]['texts'] as List).join('\n');
    expect(texts, contains('Annual Report 2024'));
    expect(es['slides'][0]['tables'][0][0], ['Region', 'Units', 'Revenue']);
    expect(es['slides'][0]['pictures'], 1);
    expect(editable.imageSlides, isEmpty);
    if (hasLibreOffice) expect(libreOfficeToPdf(writePptx(editable.deck), 'pptx'), isNotNull);
  });

  test('ACCEPTANCE 4: scanned PDF through OCR → DOCX keeps uncertain words flagged', () {
    // The ML Kit OCR engine runs only on Android; here its output is given
    // as recognised lines, which is what the converter consumes.
    const size = Size(595, 842);
    final ocrPage = PageContent(index: 0, size: size, fromOcr: true, lines: groupWordsIntoLines([
      const PdfWord('Invoice', Rect.fromLTWH(60, 60, 80, 20), size: 18, confidence: 0.98),
      const PdfWord('No.', Rect.fromLTWH(145, 60, 30, 20), size: 18, confidence: 0.97),
      const PdfWord('Total:', Rect.fromLTWH(60, 120, 50, 12), size: 11, confidence: 0.95),
      const PdfWord('1,2O0', Rect.fromLTWH(115, 120, 40, 12), size: 11, confidence: 0.41),
    ]));
    final r = buildDoc([ocrPage]);
    expect(r.warnings.join(' '), allOf(contains('OCR'), contains('low confidence')));
    final s = officeSummary(writeDocx(r.doc), 'docx');
    expect((s['paragraphs'] as List).join('\n'), contains('Total: 1,2O0'));
  });

  test('ACCEPTANCE 5: multi-page PDF → JPG/PNG/TIFF at chosen DPI, grayscale', () {
    final s = op(reportPdf());
    final png = s.renderEncoded(0, dpi: 72, format: RasterFormat.png);
    final p = img.decodePng(png)!;
    expect(p.width, 595);
    expect(p.height, 842);
    final jpg = img.decodeJpg(s.renderEncoded(1, dpi: 150, format: RasterFormat.jpg, quality: 80, grayscale: true))!;
    expect(jpg.width, closeTo(595 * 150 / 72, 2));
    final px = jpg.getPixel(100, 100);
    expect(px.r, px.g);
    expect(img.decodeTiff(s.renderEncoded(0, dpi: 50, format: RasterFormat.tiff)), isNotNull);
    s.close();
  });

  test('ACCEPTANCE 6: PPTX (tables, chart with data) → Excel', () {
    final deck = readPptx(File('${fixtures.path}/review.pptx').readAsBytesSync());
    expect(deck.slides.length, 2);
    final r = pptxToSheets(deck);
    final s = officeSummary(writeXlsx(r.sheets), 'xlsx')['sheets'] as Map<String, dynamic>;
    expect(s.keys, containsAll(['Slide text', 'Key values', 'Slide 2 table 1', 'Slide 2 chart 1']));
    final table = s['Slide 2 table 1'] as List;
    expect(table[0][0], 'Source: slide 2, table 1');
    expect(table[3], ['Pens', 40, 2.5]);
    final chart = s['Slide 2 chart 1'] as List;
    expect(chart[2], ['Category', 'North', 'South']);
    expect(chart[5], ['Q3', 150, 110]);
    final kv = s['Key values'] as List;
    expect(kv.any((row) => row[1] == 'Revenue' && row[2] == 1250000), isTrue);
    final text = (s['Slide text'] as List).map((r) => r.join('|')).join('\n');
    expect(text, contains('Margin improved'));
    expect(r.notes, isEmpty);
    // A chart without stored values is reported, not invented.
    final noData = pptxToSheets(const PresentationModel([
      SlideModel([SlideChart(Rect.fromLTWH(0, 0, 10, 10), ChartData('bar', 'X', [], [], hasData: false))])
    ]));
    expect(noData.notes.single, contains('not extracted'));
  });

  test('ACCEPTANCE 7: XLSX → PowerPoint (table slides and a native chart)', () {
    final sheets = readXlsx(File('${fixtures.path}/sales.xlsx').readAsBytesSync());
    expect(sheets.first.rows[1][1].number, 120);
    expect(sheets[1].rows[1][0].date, DateTime.utc(2025, 1, 15));
    final deck = sheetsToDeck(sheets, title: 'Sales');
    final s = officeSummary(writePptx(deck), 'pptx');
    final slides = s['slides'] as List;
    expect(slides[1]['tables'][0][0], ['Region', 'Q1', 'Q2', 'Q3']);
    final chart = slides.firstWhere((x) => (x['charts'] as List).isNotEmpty)['charts'][0];
    expect(chart['categories'], ['North', 'South', 'West']);
    expect(chart['series'][0], [120.0, 90.0, 70.0]);
    // Range selection and pagination.
    final ranged = sheetsToDeck([sheets.first], range: 'A1:B3', charts: false);
    expect(ranged.slides[1].shapes.whereType<SlideTable>().single.rows, [
      ['Region', 'Q1'],
      ['North', '120'],
      ['South', '90']
    ]);
    final many = sheetsToDeck([
      Sheet('Big', [
        for (var r = 0; r < 25; r++) [SheetCell('row $r'), SheetCell('$r', number: r.toDouble())]
      ])
    ], maxRows: 10, charts: false);
    expect(many.slides.length, 1 + 3, reason: 'title + 24 data rows in pages of 10');
  });

  test('Office → PDF: DOCX, XLSX (range), PPTX, HTML and text produce real PDFs', () {
    final r = DocPdfRenderer(freeSans);
    final docx = r.render(readDocx(File('${fixtures.path}/charter.docx').readAsBytesSync()));
    final t = viewerText(docx);
    expect(t, allOf(contains('Project Charter'), contains('March 2025'), contains('Scope item two'), contains('48000'), contains('Second page content'), contains('ACME Confidential')));
    expect(op(docx).pageCount, 2, reason: 'page break kept');
    final xlsx = DocPdfRenderer(freeSans).render(sheetsToDoc(readXlsx(File('${fixtures.path}/sales.xlsx').readAsBytesSync()), range: 'A1:C2'));
    final xt = viewerText(xlsx);
    expect(xt, allOf(contains('North'), contains('135')));
    expect(xt, isNot(contains('150')), reason: 'outside the range');
    final pptx = slidesToPdf(readPptx(File('${fixtures.path}/review.pptx').readAsBytesSync()), freeSans);
    final pt = viewerText(pptx);
    expect(pt, allOf(contains('Quarterly Review'), contains('Pens'), contains('Q2')));
    final onlySecond = slidesToPdf(readPptx(File('${fixtures.path}/review.pptx').readAsBytesSync()), freeSans, only: [1]);
    expect(op(onlySecond).pageCount, 1);
    final h = htmlToDoc('<html><head><title>T</title></head><body><h1>Heading</h1><p>Some <b>bold</b> text &amp; a <a href="https://x.org">link</a>.</p>'
        '<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>'
        '<img src="https://example.org/x.png"></body></html>');
    expect(h.notes.single, contains('not included'));
    final hp = DocPdfRenderer(freeSans).render(h.doc);
    expect(viewerText(hp), allOf(contains('Heading'), contains('Some bold text & a link.'), contains('Nested')));
    final tp = DocPdfRenderer(freeSans).render(textToDoc('Line one\nLine two\n\nSecond paragraph — ünïcode ₹'));
    expect(viewerText(tp), allOf(contains('Line two'), contains('Second paragraph — ünïcode ₹')));
  });

  test('PDF → HTML and text', () {
    final pages = contentOf(reportPdf());
    final html = docToHtml(buildDoc(pages, title: 'Report').doc);
    expect(html, allOf(contains('<h1>Annual Report 2024</h1>'), contains('<ul>'), contains('<table>'), contains('data:image/png;base64')));
    final text = pagesToText(pages);
    expect(text, allOf(contains('Overview'), contains('Toner')));
    expect(DocModel([DocParagraph([DocRun('a')])]).plainText, 'a\n');
  });

  test('ACCEPTANCE 14: every Office output reopens in independent readers (python-docx/openpyxl/python-pptx, LibreOffice when installed)', () {
    final pages = contentOf(reportPdf());
    final tables = [for (final p in pages) ...const TableExtractionService().extract(p)];
    final outputs = <String, (Uint8List, String)>{
      'PDF → Word (editable)': (writeDocx(buildDoc(pages, title: 'Report').doc), 'docx'),
      'PDF → Word (layout)': (writeDocx(buildDoc(pages, mode: WordMode.layout, title: 'Report').doc), 'docx'),
      'PDF → Excel': (writeXlsx(tablesToSheets(tables)), 'xlsx'),
      'PDF → PowerPoint (editable)': (writePptx(pagesToEditableSlides(pages, title: 'Report').deck), 'pptx'),
      'PowerPoint → Excel': (writeXlsx(pptxToSheets(readPptx(File('${fixtures.path}/review.pptx').readAsBytesSync())).sheets), 'xlsx'),
      'Excel → PowerPoint': (writePptx(sheetsToDeck(readXlsx(File('${fixtures.path}/sales.xlsx').readAsBytesSync()), title: 'Sales')), 'pptx'),
    };
    final lo = hasLibreOffice;
    for (final e in outputs.entries) {
      final (bytes, ext) = e.value;
      final summary = officeSummary(bytes, ext);
      expect(summary, isNotEmpty, reason: e.key);
      // And back through the app's own readers.
      switch (ext) {
        case 'docx':
          expect(readDocx(bytes).plainText, contains('Annual Report 2024'), reason: e.key);
        case 'xlsx':
          expect(readXlsx(bytes), isNotEmpty, reason: e.key);
        case 'pptx':
          expect(readPptx(bytes).slides, isNotEmpty, reason: e.key);
      }
      if (lo) {
        final pdf = libreOfficeToPdf(bytes, ext)!;
        expect(op(pdf).pageCount, greaterThan(0), reason: '${e.key} opened by LibreOffice');
      }
    }
    // ignore: avoid_print
    print('ACCEPTANCE 14: ${outputs.length} outputs checked; LibreOffice ${lo ? 'available and used' : 'not installed (skipped that part)'}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
