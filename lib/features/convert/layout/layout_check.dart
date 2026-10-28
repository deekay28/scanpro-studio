import 'dart:ui';

import 'layout_model.dart';

/// How each part of a rebuilt (editable) page is rendered, and whether any
/// two parts collide. One region has one strategy: text is never also a
/// picture, a picture never covers text, a table cell never overlaps text
/// placed outside the table, and no picture is the whole page.
class LayoutCoverage {
  final int textLines, tables, cells, bands, pictures;
  final List<String> problems;
  const LayoutCoverage(this.textLines, this.tables, this.cells, this.bands, this.pictures, this.problems);

  String get summary => '$textLines text line(s), $tables table(s) with $cells cell(s), $bands shaded band(s), $pictures picture(s)';
}

LayoutCoverage checkLayout(LayoutPage p) {
  final problems = <String>[];
  final area = p.size.width * p.size.height;
  double share(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    return i.width * i.height / (a.width * a.height);
  }

  if (p.background != null) problems.add('the page is a picture (not editable)');
  for (final g in p.graphics) {
    if (g.box.width * g.box.height > area * 0.6) problems.add('a picture covers most of the page');
  }
  // Pictures vs text lines and table text.
  final texts = <(String, Rect)>[
    for (final l in p.lines) (l.text, l.box),
    for (final t in p.tables)
      for (final c in t.cells)
        for (final l in c.lines) (l.text, l.box),
  ];
  for (final g in p.graphics) {
    for (final (text, box) in texts) {
      if (share(box, g.box) > 0.5) problems.add('text "${_short(text)}" lies on a picture');
    }
  }
  // Pictures vs pictures (one graphic must be inserted once).
  for (var i = 0; i < p.graphics.length; i++) {
    for (var j = i + 1; j < p.graphics.length; j++) {
      final a = p.graphics[i].box, b = p.graphics[j].box;
      if (share(a, b) > 0.2 || share(b, a) > 0.2) problems.add('two pictures overlap');
    }
  }
  // Free text vs tables.
  for (final l in p.lines) {
    for (final t in p.tables) {
      if (share(l.box, t.box) > 0.5) problems.add('text "${_short(l.text)}" is placed over a table');
    }
  }
  // Text lines vs text lines (reconstructed twice).
  for (var i = 0; i < p.lines.length; i++) {
    for (var j = i + 1; j < p.lines.length; j++) {
      final a = p.lines[i].box, b = p.lines[j].box;
      if (share(a, b) > 0.6 || share(b, a) > 0.6) problems.add('text "${_short(p.lines[i].text)}" overlaps "${_short(p.lines[j].text)}"');
    }
  }
  return LayoutCoverage(
    p.lines.length,
    p.tables.length,
    p.tables.fold(0, (n, t) => n + t.cells.length),
    p.shades.length,
    p.graphics.length,
    problems.toSet().toList(),
  );
}

String _short(String s) => s.length <= 30 ? s : '${s.substring(0, 27)}…';
