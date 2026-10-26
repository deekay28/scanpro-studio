import 'dart:math' as math;
import 'dart:ui';

import 'model/page_content.dart';

/// A cell value with its parsed type. The original text is always kept.
class TableCell {
  final String text;
  final double? number;
  final DateTime? date;
  final bool uncertain; // OCR confidence low or the value looks misread
  final bool bold;
  const TableCell(this.text, {this.number, this.date, this.uncertain = false, this.bold = false});
}

class ExtractedTable {
  final int page;
  final Rect bounds;
  final List<List<TableCell>> rows;
  final String method; // 'ruled' or 'aligned columns'
  final bool headerRow;
  final List<double> columnEdges; // x positions of column boundaries
  const ExtractedTable(this.page, this.bounds, this.rows, this.method, {this.headerRow = false, this.columnEdges = const []});

  int get columnCount => rows.fold(0, (m, r) => math.max(m, r.length));
  int get uncertainCells => rows.fold(0, (n, r) => n + r.where((c) => c.uncertain).length);
}

/// Finds tables on a page: ruled tables from vector grid lines, then
/// borderless tables from consecutive lines whose words align in columns.
/// This is heuristic: unusual layouts can produce imperfect tables, so the
/// result is always shown for review before export.
class TableExtractionService {
  const TableExtractionService();

  List<ExtractedTable> extract(PageContent page) {
    final ruled = _ruled(page);
    final used = <PdfLine>{};
    for (final t in ruled) {
      for (final l in page.lines) {
        if (t.bounds.inflate(1).contains(l.box.center)) used.add(l);
      }
    }
    final aligned = _aligned(page, page.lines.where((l) => !used.contains(l)).toList());
    final all = [...ruled, ...aligned]..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    return all;
  }

  // ---------------------------------------------------------------- ruled
  List<ExtractedTable> _ruled(PageContent page) {
    final hs = page.rules.where((r) => r.horizontal && r.length > 10).toList();
    final vs = page.rules.where((r) => r.vertical && r.length > 6).toList();
    if (hs.length < 2 || vs.length < 2) return const [];
    // Group horizontal rules into connected grids by overlap with vertical rules.
    final ys = _cluster(hs.map((r) => r.a.dy).toList(), 2);
    final xs = _cluster(vs.map((r) => r.a.dx).toList(), 2);
    if (ys.length < 2 || xs.length < 2) return const [];
    // Keep only grid lines that actually cross: a horizontal rule spanning
    // between two vertical rules.
    final left = xs.first, right = xs.last, top = ys.first, bottom = ys.last;
    final bounds = Rect.fromLTRB(left, top, right, bottom);
    if (bounds.width < 30 || bounds.height < 10) return const [];
    final rows = <List<TableCell>>[];
    for (var r = 0; r + 1 < ys.length; r++) {
      final row = <TableCell>[];
      for (var c = 0; c + 1 < xs.length; c++) {
        final cell = Rect.fromLTRB(xs[c], ys[r], xs[c + 1], ys[r + 1]);
        final words = <PdfWord>[];
        for (final l in page.lines) {
          for (final w in l.words) {
            if (cell.contains(w.box.center)) words.add(w);
          }
        }
        row.add(_cell(words));
      }
      if (row.any((c) => c.text.isNotEmpty)) rows.add(row);
    }
    if (rows.length < 2) return const [];
    return [ExtractedTable(page.index, bounds, rows, 'ruled', headerRow: _looksHeader(rows), columnEdges: xs)];
  }

  // ---------------------------------------------------------------- aligned
  List<ExtractedTable> _aligned(PageContent page, List<PdfLine> lines) {
    // Rebuild visual rows: lines that share a baseline (columns were split
    // into separate lines by the word grouping).
    final rows = <List<PdfLine>>[];
    for (final l in [...lines]..sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy))) {
      if (rows.isNotEmpty) {
        final ref = rows.last.first.box;
        if ((ref.center.dy - l.box.center.dy).abs() < math.min(ref.height, l.box.height) * 0.6) {
          rows.last.add(l);
          continue;
        }
      }
      rows.add([l]);
    }
    // Segments of each visual row: split at gaps wider than ~1.2 em.
    List<List<PdfWord>> segments(List<PdfLine> row) {
      final words = [for (final l in row) ...l.words]..sort((a, b) => a.box.left.compareTo(b.box.left));
      final out = <List<PdfWord>>[];
      for (final w in words) {
        if (out.isNotEmpty) {
          final gap = w.box.left - out.last.last.box.right;
          if (gap < math.max(w.size, out.last.last.size) * 1.2) {
            out.last.add(w);
            continue;
          }
        }
        out.add([w]);
      }
      return out;
    }

    final segs = rows.map(segments).toList();
    final tables = <ExtractedTable>[];
    var i = 0;
    while (i < rows.length) {
      if (segs[i].length < 2) {
        i++;
        continue;
      }
      // Grow a run of rows with ≥2 segments and regular spacing.
      var j = i + 1;
      while (j < rows.length && segs[j].length >= 2) {
        final gap = rows[j].first.box.top - rows[j - 1].first.box.bottom;
        if (gap > rows[j].first.size * 2.5) break;
        j++;
      }
      if (j - i >= 2) {
        final t = _buildAligned(page.index, rows.sublist(i, j), segs.sublist(i, j));
        if (t != null) tables.add(t);
      }
      i = j;
    }
    return tables;
  }

  ExtractedTable? _buildAligned(int page, List<List<PdfLine>> rows, List<List<List<PdfWord>>> segs) {
    // Column anchors: cluster segment extents across rows.
    final spans = <(double, double)>[];
    for (final row in segs) {
      for (final s in row) {
        spans.add((s.first.box.left, s.last.box.right));
      }
    }
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    final cols = <(double, double)>[];
    for (final s in spans) {
      final k = cols.indexWhere((c) => s.$1 <= c.$2 + 2 && s.$2 >= c.$1 - 2);
      if (k >= 0) {
        cols[k] = (math.min(cols[k].$1, s.$1), math.max(cols[k].$2, s.$2));
      } else {
        cols.add(s);
      }
    }
    // Merge overlapping columns created by long cells.
    cols.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final c in cols) {
      if (merged.isNotEmpty && c.$1 <= merged.last.$2 + 1) {
        merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, c.$2));
      } else {
        merged.add(c);
      }
    }
    if (merged.length < 2) return null;
    // Rows whose segments fit the columns.
    final out = <List<TableCell>>[];
    var fits = 0;
    for (final row in segs) {
      final cells = List<List<PdfWord>>.generate(merged.length, (_) => []);
      for (final s in row) {
        final mid = (s.first.box.left + s.last.box.right) / 2;
        var best = 0;
        var bestD = double.infinity;
        for (var c = 0; c < merged.length; c++) {
          final d = mid < merged[c].$1 ? merged[c].$1 - mid : (mid > merged[c].$2 ? mid - merged[c].$2 : 0.0);
          if (d < bestD) {
            bestD = d;
            best = c;
          }
        }
        cells[best].addAll(s);
      }
      if (row.length >= 2) fits++;
      out.add([for (final c in cells) _cell(c)]);
    }
    // Require a consistent shape: most rows fill at least two columns.
    if (fits < 2 || fits < out.length * 0.6) return null;
    final bounds = [for (final r in rows) for (final l in r) l.box].reduce((a, b) => a.expandToInclude(b));
    final edges = [merged.first.$1, for (var c = 1; c < merged.length; c++) (merged[c - 1].$2 + merged[c].$1) / 2, merged.last.$2];
    return ExtractedTable(page, bounds, out, 'aligned columns', headerRow: _looksHeader(out), columnEdges: edges);
  }

  // ---------------------------------------------------------------- cells
  TableCell _cell(List<PdfWord> words) {
    if (words.isEmpty) return const TableCell('');
    words.sort((a, b) {
      final dy = a.box.center.dy - b.box.center.dy;
      if (dy.abs() > math.min(a.box.height, b.box.height) * 0.5) return dy.sign.toInt();
      return a.box.left.compareTo(b.box.left);
    });
    final text = words.map((w) => w.text).join(' ').trim();
    final uncertain = words.any((w) => w.uncertain);
    final bold = words.every((w) => w.bold);
    return parseCell(text, uncertain: uncertain, bold: bold);
  }

  static bool _looksHeader(List<List<TableCell>> rows) {
    if (rows.length < 2) return false;
    final first = rows.first;
    final textual = first.where((c) => c.text.isNotEmpty && c.number == null && c.date == null).length;
    final numericBelow = rows.skip(1).expand((r) => r).where((c) => c.number != null).length;
    return first.every((c) => c.bold || c.text.isEmpty) || (textual >= first.length * 0.6 && numericBelow > 0);
  }

  static List<double> _cluster(List<double> v, double tol) {
    v.sort();
    final out = <double>[];
    for (final x in v) {
      if (out.isEmpty || x - out.last > tol) {
        out.add(x);
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Value typing
// ---------------------------------------------------------------------------

final _currency = RegExp(r'^[\s]*(?:(?:Rs\.?|INR|USD|EUR|GBP|[₹$€£¥])\s*)?([-+(]?)\s*((?:\d{1,3}(?:[,\s]\d{2,3})+|\d+)(?:\.\d+)?)\s*(\)?)\s*(%|(?:Rs\.?|INR|USD|EUR|GBP|[₹$€£¥]))?\s*(?:Cr|Dr|CR|DR)?[\s]*$');
final _dmy = RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$');
final _ymd = RegExp(r'^(\d{4})[/.\-](\d{1,2})[/.\-](\d{1,2})$');
final _dMonY = RegExp(r'^(\d{1,2})[\s\-]([A-Za-z]{3,9})[\s\-,]+(\d{2,4})$');
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// Parses a cell's text into a number or date when that is unambiguous.
/// European decimal commas and two-digit years are treated as text rather
/// than guessed.
TableCell parseCell(String text, {bool uncertain = false, bool bold = false}) {
  final t = text.trim();
  if (t.isEmpty) return TableCell('', bold: bold);
  // Values with letters mixed into digits (typical OCR confusions: O/0, l/1, S/5).
  final misread = RegExp(r'^\d+[OolISB]\d*$|^[OolISB]\d+$').hasMatch(t.replaceAll(RegExp(r'[,.\s]'), ''));
  DateTime? date;
  var m = _dmy.firstMatch(t);
  if (m != null && m.group(3)!.length == 4) {
    final d = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), y = int.parse(m.group(3)!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) date = DateTime.utc(y, mo, d);
  }
  final ymd = _ymd.firstMatch(t);
  if (ymd != null) {
    final y = int.parse(ymd.group(1)!), mo = int.parse(ymd.group(2)!), d = int.parse(ymd.group(3)!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) date = DateTime.utc(y, mo, d);
  }
  final dm = _dMonY.firstMatch(t);
  if (dm != null && dm.group(3)!.length == 4) {
    final mo = _months.indexOf(dm.group(2)!.substring(0, 3).toLowerCase()) + 1;
    final d = int.parse(dm.group(1)!);
    if (mo > 0 && d >= 1 && d <= 31) date = DateTime.utc(int.parse(dm.group(3)!), mo, d);
  }
  if (date != null) return TableCell(t, date: date, uncertain: uncertain, bold: bold);
  final c = _currency.firstMatch(t);
  if (c != null && !misread) {
    final digits = c.group(2)!.replaceAll(RegExp(r'[,\s]'), '');
    var v = double.tryParse(digits);
    if (v != null) {
      final negative = c.group(1) == '-' || (c.group(1) == '(' && c.group(3) == ')');
      if (negative) v = -v;
      if (c.group(4) == '%') v = v / 100;
      return TableCell(t, number: v, uncertain: uncertain, bold: bold);
    }
  }
  return TableCell(t, uncertain: uncertain || misread, bold: bold);
}
