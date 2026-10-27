import 'dart:math' as math;
import 'dart:ui';

import '../model/doc_model.dart' show officeFontFor;
import '../model/page_content.dart';
import 'layout_model.dart';
import 'table_grid.dart';

/// Builds a positioned layout from a digitally generated page: the PDF's own
/// words (with their fonts, sizes, weights and colours), its ruling lines
/// (tables, underlines) and its embedded images, all at their positions.
LayoutPage nativeLayout(PageContent c) {
  final page = LayoutPage(c.size);
  final words = <PdfWord>[for (final l in c.lines) ...l.words];
  final rows = _rows(words);
  // Ruled tables from the vector lines.
  final lines = <GridLine>[
    for (final r in c.rules)
      if (r.horizontal)
        GridLine(true, (r.a.dy + r.b.dy) / 2, math.min(r.a.dx, r.b.dx), math.max(r.a.dx, r.b.dx))
      else if (r.vertical)
        GridLine(false, (r.a.dx + r.b.dx) / 2, math.min(r.a.dy, r.b.dy), math.max(r.a.dy, r.b.dy)),
  ];
  final grids = findGrids(lines, width: c.size.width, height: c.size.height, rows: [for (final r in rows) [for (final w in r) w.box]]);
  final inTable = <List<PdfWord>>{};
  for (final g in grids) {
    final cellWords = <LCell, List<PdfWord>>{};
    for (final r in rows) {
      final cy = r.map((w) => w.box.center.dy).reduce((a, b) => a + b) / r.length;
      final cx = (r.first.box.left + r.last.box.right) / 2;
      if (!g.box.contains(Offset(cx, cy))) continue;
      inTable.add(r);
      for (final w in r) {
        (cellWords[g.cellAt(w.box.center)] ??= []).add(w);
      }
    }
    for (final e in cellWords.entries) {
      for (final r in _rows(e.value)) {
        e.key.lines.add(_line(r, lines));
      }
    }
    page.tables.add(LTable(g.xs, g.ys, g.cells, borderWidth: 0.75));
  }
  for (final r in rows) {
    if (inTable.contains(r)) continue;
    page.lines.add(_line(r, lines));
  }
  for (final im in c.images) {
    page.graphics.add(LGraphic(im.box, im.png, 'png', im.pixelWidth, im.pixelHeight, kind: GraphicKind.photo));
  }
  return page;
}

/// Words on the same baseline, left to right.
List<List<PdfWord>> _rows(List<PdfWord> words) {
  final sorted = [...words]..sort((a, b) => a.box.left.compareTo(b.box.left));
  final rows = <List<PdfWord>>[];
  for (final w in sorted) {
    List<PdfWord>? best;
    var bestScore = 0.0;
    for (final r in rows) {
      final last = r.last.box;
      if (w.box.left < last.left) continue;
      final ov = math.min(last.bottom, w.box.bottom) - math.max(last.top, w.box.top);
      final score = ov / math.max(0.1, math.min(last.height, w.box.height));
      if (score > 0.5 && score > bestScore) {
        best = r;
        bestScore = score;
      }
    }
    if (best == null) {
      rows.add([w]);
    } else {
      best.add(w);
    }
  }
  rows.sort((a, b) => a.first.box.top.compareTo(b.first.box.top));
  return rows;
}

LLine _line(List<PdfWord> ws, List<GridLine> rules) {
  return LLine([
    for (final w in ws)
      LWord(w.text, w.box,
          size: w.size,
          bold: w.bold,
          italic: w.italic,
          color: w.color,
          font: officeFontFor(w.font),
          underline: rules.any((r) =>
              r.horizontal && r.pos >= w.box.bottom - w.size * 0.05 && r.pos <= w.box.bottom + w.size * 0.35 && r.a <= w.box.left + w.box.width * 0.2 && r.b >= w.box.right - w.box.width * 0.2 && r.length < w.box.width * 6 + 40)),
  ]);
}
