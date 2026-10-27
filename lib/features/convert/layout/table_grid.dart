import 'dart:math' as math;
import 'dart:ui';

import 'layout_model.dart';

/// A straight ruling line: horizontal (pos = y, a..b = x range) or vertical
/// (pos = x, a..b = y range), in any coordinate space.
class GridLine {
  final bool horizontal;
  final double pos, a, b;
  final double thickness;
  const GridLine(this.horizontal, this.pos, this.a, this.b, {this.thickness = 1});
  double get length => b - a;
}

/// A ruled table: column and row boundaries and its (merged) cells.
class Grid {
  final List<double> xs, ys;
  final List<LCell> cells;
  final List<List<LCell>> owner; // [row][col] → cell covering it
  final List<GridLine> lines;
  Grid(this.xs, this.ys, this.cells, this.owner, this.lines);
  Rect get box => Rect.fromLTRB(xs.first, ys.first, xs.last, ys.last);
  int get rows => ys.length - 1;
  int get columns => xs.length - 1;

  /// The cell containing point [p] (clamped to the grid).
  LCell cellAt(Offset p) {
    var ci = 0, ri = 0;
    while (ci < columns - 1 && p.dx > xs[ci + 1]) {
      ci++;
    }
    while (ri < rows - 1 && p.dy > ys[ri + 1]) {
      ri++;
    }
    return owner[ri][ci];
  }
}

/// A text row given to [findGrids]: its words' boxes, left to right.
typedef GridTextRow = List<Rect>;

/// Finds ruled tables: groups of horizontal and vertical lines that touch,
/// with at least two of each. Close lines (double borders, slightly tilted
/// photographed lines) are clustered; a vertical line that would cut
/// through a word or a normal gap between words of a phrase is not a column
/// border. Cells merge across missing borders (row and column spans).
/// Tolerances are fractions of the page [width] and [height].
List<Grid> findGrids(List<GridLine> lines, {required double width, required double height, List<GridTextRow> rows = const []}) {
  final words = [for (final r in rows) ...r];
  // An underline: just below words that cover most of its length.
  bool underline(GridLine l) {
    final xs = <(double, double)>[];
    for (final b in words) {
      if (b.right < l.a || b.left > l.b) continue;
      final cy = b.center.dy;
      if (cy < l.pos && cy > l.pos - b.height * 1.2) xs.add((b.left - b.height * 0.5, b.right + b.height * 0.5));
    }
    if (xs.isEmpty) return false;
    xs.sort((p, q) => p.$1.compareTo(q.$1));
    var covered = 0.0, end = l.a;
    for (final (s0, e0) in xs) {
      final s1 = math.max(s0, end), e1 = math.min(e0, l.b);
      if (e1 > s1) covered += e1 - s1;
      end = math.max(end, e0);
    }
    return covered > l.length * 0.8;
  }

  final hs = lines.where((r) => r.horizontal && r.length > width * 0.12 && !underline(r)).toList();
  // A short vertical stroke inside a word is part of a letter or digit.
  bool inWord(GridLine v) {
    final mid = Offset(v.pos, (v.a + v.b) / 2);
    return words.any((b) => b.inflate(1).contains(mid) && v.length < b.height * 1.6);
  }

  final vs = lines.where((r) => !r.horizontal && r.length > height * 0.012 && !inWord(r)).toList();
  final tol = width * 0.012;
  bool touch(GridLine a, GridLine b) {
    final hr = a.horizontal ? a : b, vr = a.horizontal ? b : a;
    return vr.pos >= hr.a - tol && vr.pos <= hr.b + tol && hr.pos >= vr.a - tol && hr.pos <= vr.b + tol;
  }

  final all = [...hs, ...vs];
  final group = List<int>.filled(all.length, -1);
  var next = 0;
  for (var i = 0; i < all.length; i++) {
    if (group[i] >= 0) continue;
    group[i] = next;
    final stack = [i];
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      for (var j = 0; j < all.length; j++) {
        if (group[j] >= 0 || all[j].horizontal == all[k].horizontal) continue;
        if (touch(all[k], all[j])) {
          group[j] = next;
          stack.add(j);
        }
      }
    }
    next++;
  }
  final out = <Grid>[];
  final xTol = width * 0.022, yTol = height * 0.012;
  for (var gi = 0; gi < next; gi++) {
    final gh = [for (var i = 0; i < all.length; i++) if (group[i] == gi && all[i].horizontal) all[i]];
    final gv = [for (var i = 0; i < all.length; i++) if (group[i] == gi && !all[i].horizontal) all[i]];
    if (gh.length < 2 || gv.length < 2) continue;
    final ys = _cluster(gh.map((r) => r.pos).toList(), yTol);
    var xs = _cluster(gv.map((r) => r.pos).toList(), xTol);
    if (ys.length < 2 || xs.length < 2) continue;
    if (xs.length > 2) {
      final top = ys.first, bottom = ys.last;
      bool cuts(double x) {
        for (final row in rows) {
          if (row.isEmpty) continue;
          final cy = row.map((b) => b.center.dy).reduce((a, b) => a + b) / row.length;
          if (cy < top || cy > bottom) continue;
          final wh = median(row.map((b) => b.height));
          for (var i = 0; i < row.length; i++) {
            final b = row[i];
            if (x > b.left + b.width * 0.2 && x < b.right - b.width * 0.2) return true;
            if (i + 1 < row.length) {
              final n = row[i + 1];
              if (x > b.right && x < n.left && n.left - b.right < wh * 0.9) return true;
            }
          }
        }
        return false;
      }

      xs = [xs.first, for (var i = 1; i < xs.length - 1; i++) if (!cuts(xs[i])) xs[i], xs.last];
    }
    final box = Rect.fromLTRB(xs.first, ys.first, xs.last, ys.last);
    if (box.width < width * 0.2 || box.height < height * 0.015) continue;
    final nr = ys.length - 1, nc = xs.length - 1;
    bool vBorder(int r, int c) => gv.any((v) => (v.pos - xs[c]).abs() < xTol && v.a <= ys[r] + (ys[r + 1] - ys[r]) * 0.35 && v.b >= ys[r + 1] - (ys[r + 1] - ys[r]) * 0.35);
    bool hBorder(int r, int c) => gh.any((x) => (x.pos - ys[r]).abs() < yTol && x.a <= xs[c] + (xs[c + 1] - xs[c]) * 0.35 && x.b >= xs[c + 1] - (xs[c + 1] - xs[c]) * 0.35);
    final owner = List.generate(nr, (_) => List<LCell?>.filled(nc, null));
    final cells = <LCell>[];
    for (var r = 0; r < nr; r++) {
      for (var c = 0; c < nc; c++) {
        if (owner[r][c] != null) continue;
        var span = 1;
        while (c + span < nc && !vBorder(r, c + span) && owner[r][c + span] == null) {
          span++;
        }
        var rs = 1;
        while (r + rs < nr && !hBorder(r + rs, c) && owner[r + rs][c] == null) {
          rs++;
        }
        final cell = LCell(r, c, rowSpan: rs, colSpan: span);
        for (var rr = r; rr < r + rs; rr++) {
          for (var cc = c; cc < c + span; cc++) {
            owner[rr][cc] = cell;
          }
        }
        cells.add(cell);
      }
    }
    out.add(Grid(xs, ys, cells, [for (final row in owner) [for (final c in row) c!]], [...gh, ...gv]));
  }
  return out;
}

List<double> _cluster(List<double> v, double tol) {
  v.sort();
  final groups = <List<double>>[];
  for (final x in v) {
    if (groups.isNotEmpty && x - groups.last.last <= tol) {
      groups.last.add(x);
    } else {
      groups.add([x]);
    }
  }
  return [for (final g in groups) g.reduce((a, b) => a + b) / g.length];
}

/// Thickest-but-typical line width of a grid (median).
double gridLineWidth(Grid g) => median(g.lines.map((l) => l.thickness));

double maxD(double a, double b) => math.max(a, b);
