import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'model/doc_model.dart';
import 'ooxml/pptx.dart';
import 'ooxml/xlsx.dart';
import 'table_extraction.dart';

// ---------------------------------------------------------------------------
// HTML and text
// ---------------------------------------------------------------------------

/// HTML → [DocModel]: headings, paragraphs, lists, tables, emphasis, links
/// and embedded (data:) images. External images and styles are not fetched;
/// the app works offline. Returns notes about skipped content.
({DocModel doc, List<String> notes}) htmlToDoc(String source, {String title = ''}) {
  final d = html.parse(source);
  final blocks = <DocBlock>[];
  var skippedImages = 0;
  final docTitle = title.isNotEmpty ? title : (d.querySelector('title')?.text.trim() ?? '');

  List<DocRun> inline(dom.Node n, {bool bold = false, bool italic = false, bool underline = false, String? link}) {
    final out = <DocRun>[];
    for (final c in n.nodes) {
      if (c is dom.Text) {
        final t = c.text.replaceAll(RegExp(r'\s+'), ' ');
        if (t.isNotEmpty) out.add(DocRun(t, bold: bold, italic: italic, underline: underline, link: link));
      } else if (c is dom.Element) {
        final tag = c.localName;
        if (tag == 'br') {
          out.add(const DocRun('\n'));
          continue;
        }
        if (tag == 'script' || tag == 'style') continue;
        out.addAll(inline(c,
            bold: bold || tag == 'b' || tag == 'strong' || tag == 'th',
            italic: italic || tag == 'i' || tag == 'em',
            underline: underline || tag == 'u',
            link: tag == 'a' ? c.attributes['href'] : link));
      }
    }
    return out;
  }

  DocImage? image(dom.Element e) {
    final src = e.attributes['src'] ?? '';
    final m = RegExp(r'^data:image/(png|jpe?g);base64,(.+)$', dotAll: true).firstMatch(src);
    if (m == null) {
      skippedImages++;
      return null;
    }
    try {
      final bytes = base64Decode(m.group(2)!.replaceAll(RegExp(r'\s'), ''));
      final w = double.tryParse(e.attributes['width'] ?? '') ?? 300;
      final h = double.tryParse(e.attributes['height'] ?? '') ?? w * 0.66;
      return DocImage(bytes, w * 0.75, h * 0.75);
    } catch (_) {
      skippedImages++;
      return null;
    }
  }

  void walk(dom.Element el, {int listDepth = 0}) {
    for (final c in el.nodes) {
      if (c is dom.Text) {
        final t = c.text.trim();
        if (t.isNotEmpty) blocks.add(DocParagraph([DocRun(t)]));
        continue;
      }
      if (c is! dom.Element) continue;
      final tag = c.localName ?? '';
      switch (tag) {
        case 'h1':
          blocks.add(DocParagraph(inline(c), style: ParaStyle.h1));
        case 'h2':
          blocks.add(DocParagraph(inline(c), style: ParaStyle.h2));
        case 'h3' || 'h4' || 'h5' || 'h6':
          blocks.add(DocParagraph(inline(c), style: ParaStyle.h3));
        case 'p' || 'blockquote' || 'address' || 'figcaption' || 'caption' || 'dt' || 'dd':
          final imgs = c.querySelectorAll('img');
          final runs = inline(c);
          if (runs.any((r) => r.text.trim().isNotEmpty)) blocks.add(DocParagraph(runs));
          for (final i in imgs) {
            final im = image(i);
            if (im != null) blocks.add(im);
          }
        case 'pre':
          blocks.add(DocParagraph([DocRun(c.text, font: 'Courier New')]));
        case 'ul' || 'ol':
          for (final li in c.children.where((e) => e.localName == 'li')) {
            final nested = li.children.where((e) => e.localName == 'ul' || e.localName == 'ol').toList();
            for (final n in nested) {
              n.remove();
            }
            blocks.add(DocParagraph(inline(li), style: tag == 'ul' ? ParaStyle.bullet : ParaStyle.numbered, listLevel: listDepth));
            for (final n in nested) {
              walk(dom.Element.tag('div')..append(n), listDepth: listDepth + 1);
            }
          }
        case 'table':
          final rows = <List<DocTableCell>>[];
          var header = false;
          for (final tr in c.querySelectorAll('tr')) {
            final cells = tr.children.where((e) => e.localName == 'td' || e.localName == 'th').toList();
            if (rows.isEmpty && cells.isNotEmpty && cells.every((e) => e.localName == 'th')) header = true;
            rows.add([for (final cell in cells) parseCellDoc(cell.text.trim().replaceAll(RegExp(r'\s+'), ' '))]);
          }
          if (rows.isNotEmpty) blocks.add(DocTable(rows, headerRow: header));
        case 'img':
          final im = image(c);
          if (im != null) blocks.add(im);
        case 'hr':
          blocks.add(const DocParagraph([DocRun('')]));
        case 'script' || 'style' || 'head' || 'noscript' || 'template':
          break;
        default:
          // Containers (div, section, article, body, span used as block…).
          final hasBlocks = c.children.any((e) => const {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'table', 'section', 'article', 'pre', 'blockquote', 'img', 'header', 'footer', 'main', 'nav'}.contains(e.localName));
          if (hasBlocks) {
            walk(c, listDepth: listDepth);
          } else {
            final runs = inline(c);
            if (runs.any((r) => r.text.trim().isNotEmpty)) blocks.add(DocParagraph(runs));
          }
      }
    }
  }

  final body = d.body;
  if (body != null) walk(body);
  final notes = [if (skippedImages > 0) '$skippedImages image(s) referenced by URL or file path were not included (only embedded images are used offline).'];
  return (doc: DocModel(blocks, title: docTitle), notes: notes);
}

DocTableCell parseCellDoc(String text) {
  final c = parseCell(text);
  return DocTableCell(c.text, number: c.number);
}

/// Plain text → [DocModel]; blank lines separate paragraphs, line breaks
/// inside a paragraph are kept.
DocModel textToDoc(String text, {String title = ''}) {
  final paras = text.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
  return DocModel([
    for (final p in paras)
      if (p.contains('\f'))
        ...[for (final part in p.split('\f')) DocParagraph([DocRun(part.trimRight())])].expand((e) => [e, const DocPageBreak()]).toList()..removeLast()
      else
        DocParagraph([DocRun(p.trimRight())]),
  ], title: title);
}

// ---------------------------------------------------------------------------
// Spreadsheets
// ---------------------------------------------------------------------------

/// A cell range like "A1:D20" (inclusive, zero-based results).
({int r0, int c0, int r1, int c1})? parseRange(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final m = RegExp(r'^\s*([A-Za-z]{1,3})(\d+)\s*:\s*([A-Za-z]{1,3})(\d+)\s*$').firstMatch(s);
  if (m == null) throw FormatException('"$s" is not a cell range like A1:D20.');
  final c0 = colIndex(m.group(1)!.toUpperCase()), c1 = colIndex(m.group(3)!.toUpperCase());
  final r0 = int.parse(m.group(2)!) - 1, r1 = int.parse(m.group(4)!) - 1;
  return (r0: math.min(r0, r1), c0: math.min(c0, c1), r1: math.max(r0, r1), c1: math.max(c0, c1));
}

List<List<SheetCell>> sliceSheet(Sheet s, String? range) {
  final r = parseRange(range);
  var rows = s.rows;
  if (r != null) {
    rows = [
      for (var i = r.r0; i <= r.r1 && i < rows.length; i++) [for (var c = r.c0; c <= r.c1; c++) c < rows[i].length ? rows[i][c] : const SheetCell('')]
    ];
  }
  // Drop empty trailing columns and fully empty rows.
  final used = rows.fold<int>(0, (m, row) {
    var last = -1;
    for (var c = 0; c < row.length; c++) {
      if (!row[c].isEmpty) last = c;
    }
    return math.max(m, last + 1);
  });
  return [
    for (final row in rows)
      if (row.any((c) => !c.isEmpty)) [for (var c = 0; c < used; c++) c < row.length ? row[c] : const SheetCell('')]
  ];
}

/// Sheets (or one range) → a document of tables, landscape when wide.
DocModel sheetsToDoc(List<Sheet> sheets, {String? range, String title = ''}) {
  final blocks = <DocBlock>[];
  var maxCols = 0;
  for (var i = 0; i < sheets.length; i++) {
    final rows = sliceSheet(sheets[i], range);
    if (rows.isEmpty) continue;
    maxCols = math.max(maxCols, rows.fold(0, (m, r) => math.max(m, r.length)));
    if (blocks.isNotEmpty) blocks.add(const DocPageBreak());
    blocks.add(DocParagraph([DocRun(sheets[i].name)], style: ParaStyle.h2));
    blocks.add(DocTable([
      for (final r in rows) [for (final c in r) DocTableCell(c.text, number: c.number, bold: c.bold)]
    ], headerRow: rows.length > 1 && rows.first.every((c) => c.number == null)));
  }
  if (blocks.isEmpty) throw const FormatException('The selected sheets or range are empty.');
  final landscape = maxCols > 6;
  return DocModel(blocks, pageWidth: landscape ? 841.89 : 595.28, pageHeight: landscape ? 595.28 : 841.89, margin: 36, title: title);
}

// ---------------------------------------------------------------------------
// PowerPoint → Excel
// ---------------------------------------------------------------------------

class PptxExtractOptions {
  final List<int>? slides; // zero-based; null = all
  final bool tables;
  final bool charts;
  final bool text;
  final bool keyValues;
  final bool sheetPerSlide; // text: one sheet per slide instead of one sheet
  const PptxExtractOptions({this.slides, this.tables = true, this.charts = true, this.text = true, this.keyValues = true, this.sheetPerSlide = false});
}

SheetCell _typed(String s) {
  final c = parseCell(s);
  return SheetCell(s, number: c.number, date: c.date, uncertain: c.uncertain);
}

final _kv = RegExp(r'^\s*([^:=]{2,40}?)\s*[:=]\s*(.+?)\s*$');

/// Structured extraction from slides. Every row and sheet names its source
/// slide. Charts are exported from the values stored in the file only.
({List<Sheet> sheets, List<String> notes}) pptxToSheets(PresentationModel deck, {PptxExtractOptions o = const PptxExtractOptions()}) {
  final sheets = <Sheet>[];
  final notes = <String>[];
  final textRows = <List<SheetCell>>[
    [const SheetCell('Slide'), const SheetCell('Title'), const SheetCell('Type'), const SheetCell('Level'), const SheetCell('Text')]
  ];
  final kvRows = <List<SheetCell>>[
    [const SheetCell('Slide'), const SheetCell('Label'), const SheetCell('Value')]
  ];
  var noDataCharts = 0;
  for (var i = 0; i < deck.slides.length; i++) {
    if (o.slides != null && !o.slides!.contains(i)) continue;
    final slide = deck.slides[i];
    final n = i + 1;
    final perSlide = <List<SheetCell>>[
      [const SheetCell('Type'), const SheetCell('Level'), const SheetCell('Text')]
    ];
    var t = 0, c = 0;
    for (final s in slide.shapes) {
      switch (s) {
        case SlideTable tbl when o.tables:
          t++;
          sheets.add(Sheet('Slide $n table $t', [for (final r in tbl.rows) [for (final v in r) _typed(v)]],
              headerRows: tbl.header ? 1 : 0, note: 'Source: slide $n, table $t'));
        case SlideChart ch when o.charts:
          c++;
          if (!ch.data.hasData) {
            noDataCharts++;
            textRows.add([SheetCell('$n', number: n.toDouble()), SheetCell(slide.title), const SheetCell('Chart'), const SheetCell(''), const SheetCell('Chart without stored data — values not extracted')]);
            continue;
          }
          final d = ch.data;
          final count = math.max(d.categories.length, d.series.fold(0, (m, s) => math.max(m, s.values.length)));
          sheets.add(Sheet(
            'Slide $n chart $c',
            [
              [const SheetCell('Category'), for (final s in d.series) SheetCell(s.name)],
              for (var k = 0; k < count; k++)
                [
                  SheetCell(k < d.categories.length ? d.categories[k] : ''),
                  for (final s in d.series) k < s.values.length && s.values[k] != null ? SheetCell(_fmtNum(s.values[k]!), number: s.values[k]) : const SheetCell(''),
                ]
            ],
            headerRows: 1,
            note: 'Source: slide $n, ${d.type} chart "${d.title}" — values stored in the presentation file',
          ));
        case SlideText tx:
          for (final p in tx.paras) {
            final text = p.text.trim();
            if (text.isEmpty) continue;
            final type = tx.title ? 'Title' : (p.bullet ? 'Bullet' : 'Text');
            if (o.text) {
              textRows.add([SheetCell('$n', number: n.toDouble()), SheetCell(slide.title), SheetCell(type), SheetCell('${p.level}', number: p.level.toDouble()), _typed(text)]);
              perSlide.add([SheetCell(type), SheetCell('${p.level}', number: p.level.toDouble()), _typed(text)]);
            }
            if (o.keyValues) {
              final m = _kv.firstMatch(text);
              if (m != null && !m.group(2)!.contains(':')) kvRows.add([SheetCell('$n', number: n.toDouble()), SheetCell(m.group(1)!), _typed(m.group(2)!)]);
            }
          }
        default:
          break;
      }
    }
    if (o.text && o.sheetPerSlide && perSlide.length > 1) sheets.add(Sheet('Slide $n text', perSlide, headerRows: 1, note: 'Source: slide $n'));
  }
  final out = <Sheet>[];
  if (o.text && !o.sheetPerSlide && textRows.length > 1) out.add(Sheet('Slide text', textRows, headerRows: 1));
  if (o.keyValues && kvRows.length > 1) out.add(Sheet('Key values', kvRows, headerRows: 1, note: 'Lines of the form "Label: value"; check before use'));
  out.addAll(sheets);
  if (noDataCharts > 0) notes.add('$noDataCharts chart(s) have no stored data in the file; their values were not extracted (they are not estimated from the picture).');
  if (out.isEmpty) throw const FormatException('Nothing to extract from the selected slides.');
  return (sheets: out, notes: notes);
}

String _fmtNum(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

// ---------------------------------------------------------------------------
// Excel → PowerPoint
// ---------------------------------------------------------------------------

/// Sheets → slides: a title slide, table slides of at most [maxRows] rows
/// (header repeated) and up to [maxCols] columns, and an optional native
/// bar chart when the data has a label column and numeric columns.
PresentationModel sheetsToDeck(List<Sheet> sheets, {String title = 'Workbook', String? range, int maxRows = 10, int maxCols = 7, bool charts = true}) {
  const w = 720.0, h = 405.0;
  final slides = <SlideModel>[
    SlideModel([
      SlideText(const Rect.fromLTWH(48, 140, 624, 70), [
        SlideParagraph([DocRun(title, bold: true, size: 36, color: 0xFF1F4E79)], align: ParaAlign.center)
      ], title: true),
      SlideText(const Rect.fromLTWH(48, 220, 624, 40), [
        SlideParagraph([DocRun(sheets.map((s) => s.name).join(' · '), size: 16, color: 0xFF595959)], align: ParaAlign.center)
      ]),
    ]),
  ];
  SlideText heading(String t) => SlideText(const Rect.fromLTWH(36, 20, 648, 44), [
        SlideParagraph([DocRun(t, bold: true, size: 24, color: 0xFF1F4E79)])
      ], title: true);
  for (final s in sheets) {
    final rows = sliceSheet(s, range);
    if (rows.isEmpty) continue;
    final header = rows.first;
    final body = rows.skip(1).toList();
    final colChunks = <(int, int)>[];
    final cols = header.length;
    for (var c = 0; c < cols; c += maxCols) {
      colChunks.add((c, math.min(cols, c + maxCols)));
    }
    final pages = math.max(1, (body.length / maxRows).ceil());
    for (final (c0, c1) in colChunks) {
      for (var p = 0; p < pages; p++) {
        final chunk = body.skip(p * maxRows).take(maxRows).toList();
        final grid = [
          [for (var c = c0; c < c1; c++) header[c].text],
          for (final r in chunk) [for (var c = c0; c < c1; c++) c < r.length ? r[c].text : ''],
        ];
        final label = pages > 1 || colChunks.length > 1
            ? '${s.name} (rows ${p * maxRows + 1}–${p * maxRows + chunk.length}${colChunks.length > 1 ? ', columns ${c0 + 1}–$c1' : ''})'
            : s.name;
        final tableH = math.min(320.0, 28.0 * grid.length);
        slides.add(SlideModel([heading(label), SlideTable(Rect.fromLTWH(36, 72, 648, tableH), grid)]));
      }
    }
    if (charts && body.isNotEmpty) {
      final numeric = [
        for (var c = 1; c < cols; c++)
          if (body.where((r) => c < r.length && r[c].number != null).length >= body.length * 0.8) c
      ];
      final labelsOk = body.every((r) => r.isNotEmpty && r[0].text.trim().isNotEmpty);
      if (numeric.isNotEmpty && labelsOk && body.length <= 24) {
        final series = [
          for (final c in numeric.take(4)) ChartSeries(header[c].text, [for (final r in body) c < r.length ? r[c].number : null])
        ];
        slides.add(SlideModel([
          heading('${s.name} — chart'),
          SlideChart(const Rect.fromLTWH(48, 72, 624, 310), ChartData('bar', s.name, [for (final r in body) r[0].text], series)),
        ]));
      }
    }
  }
  if (slides.length == 1) throw const FormatException('The selected sheets or range are empty.');
  return PresentationModel(slides, width: w, height: h, title: title);
}

/// Spreadsheet sheets from extracted PDF tables (one sheet per table or per
/// page). Uncertain values are highlighted and kept as text.
List<Sheet> tablesToSheets(List<ExtractedTable> tables, {bool perPage = false}) {
  final sheets = <Sheet>[];
  if (perPage) {
    final byPage = <int, List<ExtractedTable>>{};
    for (final t in tables) {
      byPage.putIfAbsent(t.page, () => []).add(t);
    }
    for (final e in byPage.entries) {
      final rows = <List<SheetCell>>[];
      for (final t in e.value) {
        if (rows.isNotEmpty) rows.add(const []);
        rows.addAll(_rows(t));
      }
      sheets.add(Sheet('Page ${e.key + 1}', rows, note: 'Source: page ${e.key + 1} (${e.value.length} table(s))'));
    }
  } else {
    final perPageCount = <int, int>{};
    for (final t in tables) {
      final k = perPageCount[t.page] = (perPageCount[t.page] ?? 0) + 1;
      sheets.add(Sheet('Page ${t.page + 1} table $k', _rows(t), headerRows: t.headerRow ? 1 : 0, note: 'Source: page ${t.page + 1}, ${t.method}'));
    }
  }
  return sheets;
}

List<List<SheetCell>> _rows(ExtractedTable t) => [
      for (final r in t.rows) [for (final c in r) SheetCell(c.text, number: c.number, date: c.date, bold: c.bold, uncertain: c.uncertain)]
    ];

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
