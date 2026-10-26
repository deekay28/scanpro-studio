import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../model/doc_model.dart';
import 'opc.dart';

/// A spreadsheet cell value.
class SheetCell {
  final String text; // original text (always kept)
  final double? number; // numeric value when reliably parsed
  final DateTime? date; // date value when reliably parsed
  final bool bold;
  final bool uncertain; // flagged for review (shown with a comment column)
  const SheetCell(this.text, {this.number, this.date, this.bold = false, this.uncertain = false});

  bool get isEmpty => text.trim().isEmpty && number == null && date == null;
}

class Sheet {
  final String name;
  final List<List<SheetCell>> rows;
  final int headerRows; // bold and frozen
  final String? note; // written in a row above the data (e.g. source)
  const Sheet(this.name, this.rows, {this.headerRows = 0, this.note});

  int get columnCount => rows.fold(0, (m, r) => math.max(m, r.length));
}

String _col(int c) {
  var n = c + 1;
  var s = '';
  while (n > 0) {
    final m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// Excel serial date (1900 date system).
double excelSerial(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1899, 12, 30)).inDays.toDouble();

String uniqueSheetName(String name, Set<String> used) {
  var n = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (n.isEmpty) n = 'Sheet';
  if (n.length > 31) n = n.substring(0, 31);
  var candidate = n;
  var i = 2;
  while (used.contains(candidate.toLowerCase())) {
    final suffix = ' ($i)';
    candidate = (n.length + suffix.length > 31 ? n.substring(0, 31 - suffix.length) : n) + suffix;
    i++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

/// Writes an XLSX workbook (SpreadsheetML) with real typed cells.
Uint8List writeXlsx(List<Sheet> sheets, {String title = ''}) {
  if (sheets.isEmpty) throw ArgumentError('A workbook needs at least one sheet');
  final opc = OpcWriter();
  final strings = <String, int>{};
  int si(String s) => strings.putIfAbsent(s, () => strings.length);
  final wbRels = Rels();
  final wb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>');
  final used = <String>{};
  for (var i = 0; i < sheets.length; i++) {
    final s = sheets[i];
    final name = uniqueSheetName(s.name, used);
    final rid = wbRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet', 'worksheets/sheet${i + 1}.xml');
    wb.write('<sheet name="${xmlEscape(name)}" sheetId="${i + 1}" r:id="$rid"/>');
    final x = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">');
    final offset = s.note == null ? 0 : 2;
    final freeze = s.headerRows + offset;
    if (freeze > 0) {
      x.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="$freeze" topLeftCell="A${freeze + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
    }
    // Column widths from content (characters).
    final cols = s.columnCount;
    if (cols > 0) {
      x.write('<cols>');
      for (var c = 0; c < cols; c++) {
        var w = 8;
        for (final r in s.rows.take(200)) {
          if (c < r.length) w = math.max(w, math.min(60, r[c].text.length + 2));
        }
        x.write('<col min="${c + 1}" max="${c + 1}" width="$w" customWidth="1"/>');
      }
      x.write('</cols>');
    }
    x.write('<sheetData>');
    if (s.note != null) {
      x.write('<row r="1"><c r="A1" t="s" s="3"><v>${si(s.note!)}</v></c></row>');
    }
    for (var r = 0; r < s.rows.length; r++) {
      final rowNo = r + 1 + offset;
      x.write('<row r="$rowNo">');
      final row = s.rows[r];
      for (var c = 0; c < row.length; c++) {
        final cell = row[c];
        if (cell.isEmpty) continue;
        final ref = '${_col(c)}$rowNo';
        final bold = cell.bold || r < s.headerRows;
        if (cell.date != null) {
          x.write('<c r="$ref" s="2"><v>${excelSerial(cell.date!)}</v></c>');
        } else if (cell.number != null && cell.number!.isFinite) {
          x.write('<c r="$ref"${bold ? ' s="1"' : (cell.uncertain ? ' s="4"' : '')}><v>${_num(cell.number!)}</v></c>');
        } else {
          x.write('<c r="$ref" t="s"${bold ? ' s="1"' : (cell.uncertain ? ' s="4"' : '')}><v>${si(cell.text)}</v></c>');
        }
      }
      x.write('</row>');
    }
    x.write('</sheetData></worksheet>');
    opc.addXml('xl/worksheets/sheet${i + 1}.xml', x.toString(), contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml');
  }
  wb.write('</sheets></workbook>');
  wbRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles', 'styles.xml');
  wbRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings', 'sharedStrings.xml');
  opc.addXml('xl/workbook.xml', wb.toString(), contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml');
  opc.addXml('xl/_rels/workbook.xml.rels', wbRels.xml());
  final ss = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${strings.length}" uniqueCount="${strings.length}">');
  for (final s in strings.keys) {
    ss.write('<si><t xml:space="preserve">${xmlEscape(s)}</t></si>');
  }
  ss.write('</sst>');
  opc.addXml('xl/sharedStrings.xml', ss.toString(), contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml');
  opc.addXml('xl/styles.xml', _styles, contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml');
  final root = Rels()
    ..add(relOfficeDoc, 'xl/workbook.xml')
    ..add(relCore, 'docProps/core.xml')
    ..add(relApp, 'docProps/app.xml');
  opc.addXml('_rels/.rels', root.xml());
  opc.addXml('docProps/core.xml', corePropsXml(title), contentType: 'application/vnd.openxmlformats-package.core-properties+xml');
  opc.addXml('docProps/app.xml', appPropsXml(), contentType: 'application/vnd.openxmlformats-officedocument.extended-properties+xml');
  return opc.finish();
}

String _num(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

// Styles: 0 normal, 1 bold, 2 date, 3 italic grey note, 4 uncertain (yellow fill).
const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font>'
    '<font><i/><sz val="10"/><color rgb="FF666666"/><name val="Calibri"/></font></fonts>'
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

int colIndex(String ref) {
  var c = 0;
  for (final ch in ref.codeUnits) {
    if (ch < 65 || ch > 90) break;
    c = c * 26 + (ch - 64);
  }
  return c - 1;
}

/// Reads all worksheets of an XLSX (values as displayed: numbers, dates,
/// strings, booleans; formulas use their cached values).
List<Sheet> readXlsx(Uint8List bytes) {
  final opc = OpcReader(bytes);
  var wbPath = 'xl/workbook.xml';
  for (final r in opc.rels('').values) {
    if (r.$1.endsWith('/officeDocument')) wbPath = r.$2;
  }
  final wb = opc.xml(wbPath);
  if (wb == null) throw const FormatException('This XLSX has no workbook.');
  final rels = opc.rels(wbPath);
  final shared = <String>[];
  String? sharedPath, stylesPath;
  for (final r in rels.values) {
    if (r.$1.endsWith('/sharedStrings')) sharedPath = r.$2;
    if (r.$1.endsWith('/styles')) stylesPath = r.$2;
  }
  final sst = sharedPath == null ? null : opc.xml(sharedPath);
  if (sst != null) {
    for (final si in sst.rootElement.kids('si')) {
      shared.add(si.all('t').where((t) => t.parentElement?.local != 'rPh').map((t) => t.innerText).join());
    }
  }
  // Which cell styles are dates.
  final dateStyles = <int>{};
  final st = stylesPath == null ? null : opc.xml(stylesPath);
  if (st != null) {
    final custom = <int, String>{};
    for (final f in st.rootElement.all('numFmt')) {
      custom[int.tryParse(f.attr('numFmtId') ?? '') ?? -1] = (f.attr('formatCode') ?? '').toLowerCase();
    }
    final xfs = st.rootElement.kid('cellXfs')?.kids('xf').toList() ?? const [];
    for (var i = 0; i < xfs.length; i++) {
      final id = int.tryParse(xfs[i].attr('numFmtId') ?? '0') ?? 0;
      final code = custom[id]?.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]'), '');
      if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47) || (code != null && RegExp(r'[dy]').hasMatch(code))) dateStyles.add(i);
    }
  }
  final out = <Sheet>[];
  for (final s in wb.rootElement.all('sheet')) {
    final name = s.attr('name') ?? 'Sheet${out.length + 1}';
    final rel = rels[s.rid ?? ''];
    if (rel == null) continue;
    final x = opc.xml(rel.$2);
    if (x == null) continue;
    final rows = <List<SheetCell>>[];
    for (final row in x.rootElement.all('row')) {
      final r = (int.tryParse(row.attr('r') ?? '') ?? (rows.length + 1)) - 1;
      while (rows.length <= r) {
        rows.add([]);
      }
      final cells = rows[r];
      var next = 0;
      for (final c in row.kids('c')) {
        final ref = c.attr('r');
        final ci = ref == null ? next : colIndex(ref);
        next = ci + 1;
        final t = c.attr('t') ?? 'n';
        final v = c.kid('v')?.innerText;
        final style = int.tryParse(c.attr('s') ?? '') ?? 0;
        SheetCell cell;
        switch (t) {
          case 's':
            final idx = int.tryParse(v ?? '') ?? -1;
            cell = SheetCell(idx >= 0 && idx < shared.length ? shared[idx] : '');
          case 'inlineStr':
            cell = SheetCell(c.all('t').map((e) => e.innerText).join());
          case 'str':
            cell = SheetCell(v ?? '');
          case 'b':
            cell = SheetCell(v == '1' ? 'TRUE' : 'FALSE');
          case 'e':
            cell = SheetCell(v ?? '#ERROR');
          default:
            final n = double.tryParse(v ?? '');
            if (n == null) {
              cell = SheetCell(v ?? '');
            } else if (dateStyles.contains(style)) {
              final d = DateTime.utc(1899, 12, 30).add(Duration(days: n.floor()));
              cell = SheetCell('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}', date: d);
            } else {
              cell = SheetCell(_num(n), number: n);
            }
        }
        while (cells.length <= ci) {
          cells.add(const SheetCell(''));
        }
        cells[ci] = cell;
      }
    }
    // Trim trailing empty rows.
    while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
      rows.removeLast();
    }
    out.add(Sheet(name, rows));
  }
  return out;
}

