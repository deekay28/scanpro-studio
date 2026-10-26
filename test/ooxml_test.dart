import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/features/convert/model/doc_model.dart';
import 'package:scanpro_studio/features/convert/ooxml/docx.dart';
import 'package:scanpro_studio/features/convert/ooxml/pptx.dart';
import 'package:scanpro_studio/features/convert/ooxml/xlsx.dart';

import 'convert_support.dart';

Uint8List png(int w, int h) => Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(200, 30, 30))));

void main() {
  test('DOCX writer output opens in python-docx and LibreOffice; reader round-trips', () {
    final m = DocModel([
      const DocParagraph([DocRun('Quarterly report')], style: ParaStyle.title),
      const DocParagraph([DocRun('Summary')], style: ParaStyle.h1),
      const DocParagraph([DocRun('Revenue grew '), DocRun('12%', bold: true), DocRun(' & costs <fell>.', italic: true, color: 0xFFC62828)]),
      const DocParagraph([DocRun('First point')], style: ParaStyle.bullet),
      const DocParagraph([DocRun('Second point')], style: ParaStyle.bullet),
      const DocTable([
        [DocTableCell('Item'), DocTableCell('Amount')],
        [DocTableCell('Paper'), DocTableCell('1,200.50')],
      ], headerRow: true),
      DocImage(png(40, 20), 120, 60),
      const DocPageBreak(pageWidth: 595.28, pageHeight: 841.89),
      const DocParagraph([DocRun('Page two text', link: 'https://example.org')]),
      DocImage(png(30, 30), 50, 50, x: 100, y: 200),
    ], header: 'ACME Ltd', footer: 'Confidential', title: 'Report', pageWidth: 841.89, pageHeight: 595.28);
    final bytes = writeDocx(m);
    final s = officeSummary(bytes, 'docx');
    expect(s['paragraphs'], containsAll(['Quarterly report', 'Summary', 'Revenue grew 12% & costs <fell>.', 'First point', 'Page two text']));
    expect(s['styles'], containsAll(['Title', 'Heading 1', 'List Paragraph']));
    expect(s['bold_runs'], contains('12%'));
    expect(s['tables'], [
      [
        ['Item', 'Amount'],
        ['Paper', '1,200.50']
      ]
    ]);
    expect(s['sections'], 2, reason: 'per-page section keeps page sizes');
    expect(s['header'], 'ACME Ltd');
    expect(s['footer'], 'Confidential');
    expect(s['images'], greaterThanOrEqualTo(2));
    if (hasLibreOffice) expect(libreOfficeToPdf(bytes, 'docx'), isNotNull);

    final back = readDocx(bytes);
    expect(back.blocks.whereType<DocParagraph>().map((p) => p.style), containsAll([ParaStyle.title, ParaStyle.h1, ParaStyle.bullet]));
    expect(back.blocks.whereType<DocTable>().single.rows[1][1].text, '1,200.50');
    expect(back.blocks.whereType<DocImage>().length, 2);
    expect(back.header, 'ACME Ltd');
    expect(back.pageWidth, closeTo(841.89, 0.1));
    final p = back.blocks.whereType<DocParagraph>().firstWhere((p) => p.text.startsWith('Revenue'));
    expect(p.runs.firstWhere((r) => r.text == '12%').bold, isTrue);
    expect(p.runs.last.color, 0xFFC62828);
  });

  test('XLSX writer: typed cells, dates, several sheets; reader round-trips', () {
    final sheets = [
      Sheet('Invoices', [
        [const SheetCell('Date'), const SheetCell('Item'), const SheetCell('Amount')],
        [SheetCell('01/03/2024', date: DateTime.utc(2024, 3, 1)), const SheetCell('Paper'), const SheetCell('₹1,200.50', number: 1200.5)],
        [SheetCell('02/03/2024', date: DateTime.utc(2024, 3, 2)), const SheetCell('Ink & toner'), const SheetCell('8O0', uncertain: true)],
      ], headerRows: 1, note: 'Source: page 1'),
      const Sheet('Invoices', [
        [SheetCell('x')]
      ]),
    ];
    final bytes = writeXlsx(sheets);
    final s = officeSummary(bytes, 'xlsx')['sheets'] as Map<String, dynamic>;
    expect(s.keys, ['Invoices', 'Invoices (2)']);
    final rows = s['Invoices'] as List;
    expect(rows[0][0], 'Source: page 1');
    expect(rows[2], ['Date', 'Item', 'Amount']);
    expect(rows[3][0], startsWith('2024-03-01'));
    expect(rows[3][2], 1200.5);
    expect(rows[4][2], '8O0', reason: 'uncertain values stay as text');
    if (hasLibreOffice) expect(libreOfficeToPdf(bytes, 'xlsx'), isNotNull);
    final back = readXlsx(bytes);
    expect(back.first.rows[3][2].number, 1200.5);
    expect(back.first.rows[3][0].date, DateTime.utc(2024, 3, 1));
    expect(back.first.rows[4][1].text, 'Ink & toner');
  });

  test('PPTX writer: text, picture, table and native chart open in python-pptx and LibreOffice; reader round-trips', () {
    final m = PresentationModel([
      const SlideModel([
        SlideText(Rect.fromLTWH(40, 30, 640, 60), [
          SlideParagraph([DocRun('Sales 2024', bold: true, size: 32)])
        ], title: true),
        SlideText(Rect.fromLTWH(40, 100, 300, 200), [
          SlideParagraph([DocRun('Growth in all regions')], bullet: true),
          SlideParagraph([DocRun('North +12%')], bullet: true, level: 1),
        ]),
      ]),
      SlideModel([
        SlidePicture(const Rect.fromLTWH(0, 0, 720, 405), png(64, 36)),
        const SlideTable(Rect.fromLTWH(40, 40, 400, 120), [
          ['Region', 'Q1', 'Q2'],
          ['North', '10', '12'],
          ['South', '7', '9'],
        ]),
        const SlideChart(
            Rect.fromLTWH(400, 200, 300, 180),
            ChartData('bar', 'Quarterly', ['Q1', 'Q2'], [
              ChartSeries('North', [10, 12]),
              ChartSeries('South', [7, 9]),
            ])),
      ]),
    ], width: 720, height: 405, title: 'Deck');
    final bytes = writePptx(m);
    final s = officeSummary(bytes, 'pptx');
    expect(s['width'], 720 * 12700);
    final slides = s['slides'] as List;
    expect(slides[0]['texts'], containsAll(['Sales 2024', 'Growth in all regions\nNorth +12%']));
    expect(slides[1]['pictures'], 1);
    expect(slides[1]['tables'][0][1], ['North', '10', '12']);
    expect(slides[1]['charts'][0]['categories'], ['Q1', 'Q2']);
    expect(slides[1]['charts'][0]['series'][1], [7.0, 9.0]);
    if (hasLibreOffice) expect(libreOfficeToPdf(bytes, 'pptx'), isNotNull);
    final back = readPptx(bytes);
    expect(back.slides[0].title, 'Sales 2024');
    final para = (back.slides[0].shapes[1] as SlideText).paras[1];
    expect(para.level, 1);
    expect(para.bullet, isTrue);
    final chart = back.slides[1].shapes.whereType<SlideChart>().single.data;
    expect(chart.categories, ['Q1', 'Q2']);
    expect(chart.series[0].values, [10, 12]);
    expect(back.slides[1].shapes.whereType<SlideTable>().single.rows[2], ['South', '7', '9']);
  });
}
