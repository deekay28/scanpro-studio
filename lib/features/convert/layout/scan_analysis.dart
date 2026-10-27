import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

import '../../../imaging/image_ops.dart';
import '../../../imaging/perspective.dart';
import '../model/page_content.dart' show PdfWord;
import 'layout_model.dart';

/// A scanned or photographed page prepared for analysis: the paper is found
/// and perspective-corrected (for analysis only; the source is unchanged).
class PreparedScan {
  final Rgb rectified; // paper, straightened
  final List<Pt>? quad; // paper corners in source pixels (TL, TR, BR, BL); null = whole image
  final int sourceWidth, sourceHeight;
  final Rect pageRect; // where the source image sits on the page (points)
  final Uint8List png; // the rectified image, for OCR
  PreparedScan(this.rectified, this.quad, this.sourceWidth, this.sourceHeight, this.pageRect, this.png);
}

/// Finds the paper in a page photo and straightens it. [rgba] is the photo
/// (or the rendered page) and [pageRect] where it sits on the page, in points.
PreparedScan prepareScan(Uint8List rgba, int w, int h, Rect pageRect) {
  final src = Uint8List(w * h * 3);
  for (var i = 0, j = 0; i < w * h; i++, j += 3) {
    src[j] = rgba[i * 4];
    src[j + 1] = rgba[i * 4 + 1];
    src[j + 2] = rgba[i * 4 + 2];
  }
  final rgb = Rgb(w, h, src);
  final quad = findPaperQuad(toGray(rgb), w, h);
  Rgb rect;
  if (quad != null) {
    final top = quad[0].dist(quad[1]), bottom = quad[3].dist(quad[2]);
    final left = quad[0].dist(quad[3]), right = quad[1].dist(quad[2]);
    final ow = ((top + bottom) / 2).round(), oh = ((left + right) / 2).round();
    rect = warpPerspective(rgb, quad, ow, oh);
  } else {
    rect = rgb;
  }
  final im = img.Image.fromBytes(width: rect.width, height: rect.height, bytes: rect.data.buffer, numChannels: 3);
  return PreparedScan(rect, quad, w, h, pageRect, Uint8List.fromList(img.encodePng(im, level: 1)));
}

/// Finds the sheet of paper in a photo: the dark background connected to
/// the image border is flood-filled, then a straight line is fitted to the
/// middle part of each paper edge (folded or torn corners don't skew it) and
/// the lines are intersected. Returns null for flat scans (no background).
List<Pt>? findPaperQuad(Uint8List gray, int w, int h) {
  final f = math.max(1, (math.max(w, h) / 600).ceil());
  final sw = w ~/ f, sh = h ~/ f;
  final g = Uint8List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      g[y * sw + x] = gray[(y * f) * w + x * f];
    }
  }
  final blurred = boxBlurU8(g, sw, sh, 2);
  final t = otsuThreshold(blurred);
  // Background: dark pixels connected to the border.
  final bg = Uint8List(sw * sh);
  final stack = <int>[];
  void seed(int i) {
    if (bg[i] == 0 && blurred[i] < t) {
      bg[i] = 1;
      stack.add(i);
    }
  }

  for (var x = 0; x < sw; x++) {
    seed(x);
    seed((sh - 1) * sw + x);
  }
  for (var y = 0; y < sh; y++) {
    seed(y * sw);
    seed(y * sw + sw - 1);
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % sw, y = i ~/ sw;
    if (x > 0) seed(i - 1);
    if (x < sw - 1) seed(i + 1);
    if (y > 0) seed(i - sw);
    if (y < sh - 1) seed(i + sw);
  }
  var bgCount = 0;
  for (final v in bg) {
    bgCount += v;
  }
  if (bgCount < sw * sh * 0.01 || bgCount > sw * sh * 0.6) return null;
  // Edge samples: first paper pixel from each side along rows/columns in
  // the middle 70% of the side.
  (double, double)? fit(List<(double, double)> pts) {
    // Robust least squares v = a*u + b, twice with outlier rejection.
    var sel = pts;
    (double, double)? line;
    for (var pass = 0; pass < 3; pass++) {
      if (sel.length < 8) return line;
      var su = 0.0, sv = 0.0, suu = 0.0, suv = 0.0;
      for (final (u, v) in sel) {
        su += u;
        sv += v;
        suu += u * u;
        suv += u * v;
      }
      final n = sel.length;
      final den = n * suu - su * su;
      if (den.abs() < 1e-9) return line;
      final a = (n * suv - su * sv) / den, b = (sv - a * su) / n;
      line = (a, b);
      final res = [for (final (u, v) in sel) (v - (a * u + b)).abs()]..sort();
      final lim = math.max(2.0, res[(res.length * 0.7).floor()] * 2);
      sel = [for (final (u, v) in sel) if ((v - (a * u + b)).abs() <= lim) (u, v)];
    }
    return line;
  }

  final left = <(double, double)>[], right = <(double, double)>[], top = <(double, double)>[], bottom = <(double, double)>[];
  for (var y = (sh * 0.15).floor(); y < sh * 0.85; y++) {
    var x = 0;
    while (x < sw && bg[y * sw + x] == 1) {
      x++;
    }
    left.add((y.toDouble(), x.toDouble()));
    x = sw - 1;
    while (x >= 0 && bg[y * sw + x] == 1) {
      x--;
    }
    right.add((y.toDouble(), x + 1.0));
  }
  for (var x = (sw * 0.15).floor(); x < sw * 0.85; x++) {
    var y = 0;
    while (y < sh && bg[y * sw + x] == 1) {
      y++;
    }
    top.add((x.toDouble(), y.toDouble()));
    y = sh - 1;
    while (y >= 0 && bg[y * sw + x] == 1) {
      y--;
    }
    bottom.add((x.toDouble(), y + 1.0));
  }
  final l = fit(left), r = fit(right), tp = fit(top), bt = fit(bottom);
  if (l == null || r == null || tp == null || bt == null) return null;
  // x = a*y + b (sides) and y = c*x + d (top/bottom) → intersections.
  Pt meet((double, double) side, (double, double) tb) {
    final (a, b) = side;
    final (c, d) = tb;
    final y = (c * b + d) / (1 - c * a);
    return Pt((a * y + b) * f, y * f);
  }

  final q = [meet(l, tp), meet(r, tp), meet(r, bt), meet(l, bt)];
  final area = polygonArea(q).abs() / (w * h);
  if (!isConvexQuad(q) || area < 0.4 || area > 1.05) return null;
  // Already straight and filling the frame: nothing to correct.
  final straight = q.every((p) => p.x > -w * 0.02 && p.y > -h * 0.02 && p.x < w * 1.02 && p.y < h * 1.02) && area > 0.985;
  return straight ? null : q;
}

/// The pixels of [r] (rounded) from an RGBA image.
(Uint8List, int, int) cropRgba(Uint8List rgba, int w, int h, Rect r) {
  final x0 = math.max(0, r.left.round()), y0 = math.max(0, r.top.round());
  final x1 = math.min(w, r.right.round()), y1 = math.min(h, r.bottom.round());
  if (x0 == 0 && y0 == 0 && x1 == w && y1 == h) return (rgba, w, h);
  final cw = x1 - x0, ch = y1 - y0;
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    out.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, ((y0 + y) * w + x0) * 4);
  }
  return (out, cw, ch);
}

class _Rule {
  final bool horizontal;
  double pos; // y for horizontal, x for vertical (px)
  double a, b; // extent along the rule
  double thickness;
  _Rule(this.horizontal, this.pos, this.a, this.b, this.thickness);
  double get length => b - a;
}

class _Comp {
  int x0, y0, x1, y1;
  int ink = 0, colored = 0;
  _Comp(this.x0, this.y0, this.x1, this.y1);
  Rect get rect => Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0);
}

/// Builds an editable layout from a prepared scan and the OCR words found in
/// [PreparedScan.png] (pixel coordinates of the rectified image).
LayoutPage buildScanLayout(PreparedScan s, List<PdfWord> ocrWords, Size pageSize, {bool markUncertain = true, void Function(String name, Uint8List png)? debug}) {
  final a = _ScanAnalyzer(s, ocrWords, pageSize, markUncertain)..debug = debug;
  return a.run();
}

class _ScanAnalyzer {
  final PreparedScan s;
  final List<PdfWord> ocr;
  final Size pageSize;
  final bool markUncertain;
  _ScanAnalyzer(this.s, this.ocr, this.pageSize, this.markUncertain);

  late final Rgb im = s.rectified;
  late final int w = im.width, h = im.height;
  late Uint8List norm; // illumination-corrected gray (paper ≈ 248)
  late Uint8List raw; // gray as photographed
  late Uint8List outside; // 1 = background around the paper
  Uint8List? lineMask; // pixels of traced ruling lines
  late Rgb clean; // illumination-corrected colour (for crops)
  late Uint8List ink; // 1 = ink
  late Uint8List colored; // 1 = saturated (coloured) ink
  late Uint8List faint; // 1 = any mark clearly darker than paper (faint stamps)
  final warnings = <String>[];
  void Function(String name, Uint8List png)? debug;

  void _dump(String name, Uint8List mask) {
    if (debug == null) return;
    final o = img.Image(width: w, height: h, numChannels: 1);
    for (var i = 0; i < w * h; i++) {
      o.setPixelR(i % w, i ~/ w, mask[i] == 1 ? 0 : 255);
    }
    debug!(name, Uint8List.fromList(img.encodePng(o)));
  }

  // Rectified pixels → source page points.
  late final Homography? _back = s.quad == null
      ? null
      : Homography.fromPoints([const Pt(0, 0), Pt(w.toDouble(), 0), Pt(w.toDouble(), h.toDouble()), Pt(0, h.toDouble())], s.quad!);
  late final double _kx = s.pageRect.width / s.sourceWidth, _ky = s.pageRect.height / s.sourceHeight;

  Offset _map(double x, double y) {
    final p = _back?.apply(Pt(x, y)) ?? Pt(x, y);
    return Offset(s.pageRect.left + p.x * _kx, s.pageRect.top + p.y * _ky);
  }

  Rect mapRect(Rect r) {
    final c = _map(r.center.dx, r.center.dy);
    final l = _map(r.left, r.center.dy), rr = _map(r.right, r.center.dy);
    final t = _map(r.center.dx, r.top), b = _map(r.center.dx, r.bottom);
    return Rect.fromCenter(center: c, width: (rr - l).distance, height: (b - t).distance);
  }

  /// Points per rectified pixel near [r].
  double scaleAt(Rect r) {
    final l = _map(r.left, r.center.dy), rr = _map(r.right, r.center.dy);
    return r.width <= 0 ? _kx : (rr - l).distance / r.width;
  }

  LayoutPage run() {
    _masks();
    _dump('ink', ink);
    _dump('colored', colored);
    debug?.call('rectified', s.png);
    // Ruling lines are searched in the ink outside recognised words, so the
    // strokes of letters are never taken for table borders.
    final lineInk = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      if (norm[i] < 185 || ink[i] == 1) lineInk[i] = 1;
    }
    for (final o in ocr) {
      final t = o.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      if (t.isEmpty || (o.confidence ?? 0.8) < 0.3) continue;
      _clear(lineInk, o.box.deflate(1));
    }
    final rules = _rules(lineInk);
    final words = <PdfWord>[
      for (final o in ocr)
        if (_cleanWord(o) case final c?) _trimToInk(o, c),
    ];
    // Shaded bands first, so they are not taken for graphics.
    final preRows = _rows(_styleWords(words, rules));
    final shadeBoxes = _shades(preRows);
    final graphics = _graphics(rules, words, shadeBoxes.map((x) => x.$1).toList());
    final graphicRects = graphics.map((g) => g.$1).toList();
    // Text that belongs to a graphic (stamp text, handwriting read as text).
    // Text inside a graphic is part of it (stamp text, handwriting read as
    // text) unless it is clearly printed text, which is never dropped.
    final textWords = words.where((wd) {
      final c = wd.box.center;
      for (final r in graphicRects) {
        if (r.contains(c) && !_looksLikeText(wd)) return false;
      }
      return true;
    }).toList();
    final styled = _styleWords(textWords, rules);
    final rows = _rows(styled);
    _markUnderlines(rows, rules);
    final tableRules = rules.where((r) {
      final rr = r.horizontal ? Rect.fromLTRB(r.a, r.pos - 1, r.b, r.pos + 1) : Rect.fromLTRB(r.pos - 1, r.a, r.pos + 1, r.b);
      return !graphicRects.any((g) => g.inflate(4).contains(rr.topLeft) && g.inflate(4).contains(rr.bottomRight));
    }).toList();
    final tables = _tables(tableRules, rows);
    if (debug != null) {
      final o = img.Image.fromBytes(width: w, height: h, bytes: im.data.buffer, numChannels: 3).clone();
      void box(Rect r, img.Color c) => img.drawRect(o, x1: r.left.round(), y1: r.top.round(), x2: r.right.round(), y2: r.bottom.round(), color: c, thickness: 3);
      for (final wd in words) {
        box(wd.box, img.ColorRgb8(150, 150, 150));
      }
      for (final r in rules) {
        final c = img.ColorRgb8(255, 0, 0);
        if (r.horizontal) {
          img.drawLine(o, x1: r.a.round(), y1: r.pos.round(), x2: r.b.round(), y2: r.pos.round(), color: c, thickness: 3);
        } else {
          img.drawLine(o, x1: r.pos.round(), y1: r.a.round(), x2: r.pos.round(), y2: r.b.round(), color: c, thickness: 3);
        }
      }
      for (final g in graphics) {
        box(g.$1, img.ColorRgb8(0, 0, 255));
      }
      for (final sb in shadeBoxes) {
        box(sb.$1, img.ColorRgb8(0, 180, 0));
      }
      debug!('overlay', Uint8List.fromList(img.encodePng(o.convert(numChannels: 3), level: 1)));
      _dump('faint', faint);
    }
    final inTables = <_Row>{for (final t in tables) ...t.$2};
    final shades = shadeBoxes.where((sb) => !tables.any((t) => mapRect(sb.$1).overlaps(t.$1.box))).toList();
    // Map everything to page points.
    final page = LayoutPage(pageSize, fromScan: true, warnings: warnings);
    for (final r in rows) {
      if (inTables.contains(r)) continue;
      page.lines.add(_toLine(r.words));
    }
    for (final (t, _) in tables) {
      page.tables.add(t);
    }
    for (final sh in shades) {
      page.shades.add(LShade(mapRect(sh.$1), sh.$2));
    }
    for (final (r, kind) in graphics) {
      page.graphics.add(_crop(r, kind));
    }
    _harmoniseSizes(page);
    final uncertain = [for (final l in page.lines) ...l.words.where((x) => x.uncertain)].length +
        [for (final t in page.tables) for (final c in t.cells) for (final l in c.lines) ...l.words.where((x) => x.uncertain)].length;
    if (uncertain > 0) {
      warnings.add('$uncertain word(s) were recognised with low confidence${markUncertain ? ' and are highlighted' : ''}; check them against the original.');
    }
    return page;
  }

  // ---- pixels -------------------------------------------------------------

  void _masks() {
    final g = toGray(im);
    raw = g;
    final bg = estimateBackground(g, w, h, minRatio: 0.5);
    norm = Uint8List(w * h);
    clean = im.clone();
    final d = im.data, cd = clean.data;
    ink = Uint8List(w * h);
    colored = Uint8List(w * h);
    faint = Uint8List(w * h);
    for (var i = 0, j = 0; i < w * h; i++, j += 3) {
      final k = 248 / math.max(bg[i], 1);
      final n = clamp255(g[i] * k);
      norm[i] = n;
      final r = clamp255(d[j] * k), gg = clamp255(d[j + 1] * k), b = clamp255(d[j + 2] * k);
      final mx = math.max(r, math.max(gg, b)), mn = math.min(r, math.min(gg, b));
      final sat = mx - mn;
      // Paper (including faint noise) becomes white in the clean copy.
      if (n > 222 && sat < 40) {
        cd[j] = 255;
        cd[j + 1] = 255;
        cd[j + 2] = 255;
      } else {
        cd[j] = r;
        cd[j + 1] = gg;
        cd[j + 2] = b;
      }
      if (n < 150) ink[i] = 1;
      if (sat > 20 && n < 225) {
        colored[i] = 1;
        ink[i] = 1;
      }
    }
    // Faint marks (stamps, seals, light pencil): clearly darker than their
    // surroundings, so smooth shadows and folds in photos don't count.
    final local = boxBlurU8(norm, w, h, math.max(4, (w * 0.008).round()));
    for (var i = 0; i < w * h; i++) {
      if (norm[i] < 165 || (norm[i] < 215 && norm[i] < local[i] - 16)) faint[i] = 1;
    }
    // Background around the paper (dark, touching the image border) is not
    // content.
    final out = Uint8List(w * h);
    final stack = <int>[];
    void seed(int i) {
      if (out[i] == 0 && norm[i] < 110) {
        out[i] = 1;
        stack.add(i);
      }
    }

    for (var x = 0; x < w; x++) {
      seed(x);
      seed((h - 1) * w + x);
    }
    for (var y = 0; y < h; y++) {
      seed(y * w);
      seed(y * w + w - 1);
    }
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % w, y = i ~/ w;
      if (x > 0) seed(i - 1);
      if (x < w - 1) seed(i + 1);
      if (y > 0) seed(i - w);
      if (y < h - 1) seed(i + w);
    }
    // Grow the background a little (its soft edge).
    final grow = (w * 0.006).ceil();
    outside = Uint8List.fromList(out);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (out[y * w + x] == 0) continue;
        if (x > 0 && out[y * w + x - 1] == 1 && x < w - 1 && out[y * w + x + 1] == 1 && y > 0 && out[(y - 1) * w + x] == 1 && y < h - 1 && out[(y + 1) * w + x] == 1) continue;
        for (var yy = math.max(0, y - grow); yy <= math.min(h - 1, y + grow); yy++) {
          outside.fillRange(yy * w + math.max(0, x - grow), yy * w + math.min(w, x + grow + 1), 1);
        }
      }
    }
    for (var i = 0; i < w * h; i++) {
      if (outside[i] == 1) {
        norm[i] = 255;
        ink[i] = 0;
        colored[i] = 0;
        faint[i] = 0;
        final j = i * 3;
        cd[j] = 255;
        cd[j + 1] = 255;
        cd[j + 2] = 255;
      }
    }
  }

  // ---- ruling lines -------------------------------------------------------

  /// Horizontal and vertical lines in [m]. Lines are traced from seed runs,
  /// following the ink with a drift of up to two pixels per step and gaps of
  /// a few pixels, so borders of curled or slightly tilted paper are found
  /// as single lines. Collinear pieces are joined afterwards.
  List<_Rule> _rules(Uint8List m) {
    final out = <_Rule>[];
    for (final horizontal in [true, false]) {
      final minLen = horizontal ? math.max(24, (w * 0.035).round()) : math.max(14, (h * 0.012).round());
      final major = horizontal ? h : w, minor = horizontal ? w : h;
      bool at(int line, int x) => line >= 0 && line < major && x >= 0 && x < minor && m[horizontal ? line * w + x : x * w + line] == 1;
      // Seeds: runs of at least half the minimum length.
      final seeds = <(int, int, int)>[];
      final seedLen = math.max(10, minLen ~/ 2);
      for (var y = 0; y < major; y++) {
        var start = -1;
        for (var x = 0; x <= minor; x++) {
          if (x < minor && at(y, x)) {
            if (start < 0) start = x;
          } else if (start >= 0) {
            if (x - start >= seedLen) seeds.add((y, start, x));
            start = -1;
          }
        }
      }
      seeds.sort((p, q) => (q.$3 - q.$2).compareTo(p.$3 - p.$2));
      final visited = Uint8List(w * h);
      void visit(int line, int x) {
        for (var d = -3; d <= 3; d++) {
          final l = line + d;
          if (l < 0 || l >= major) continue;
          visited[horizontal ? l * w + x : x * w + l] = 1;
        }
      }

      bool seen(int line, int x) => visited[horizontal ? line * w + x : x * w + line] == 1;
      lineMask ??= Uint8List(w * h);
      final rules = <_Rule>[];
      for (final (y0, s0, e0) in seeds) {
        final mid = (s0 + e0) ~/ 2;
        if (seen(y0, mid)) continue;
        // Thickness at the seed.
        var t0 = y0, t1 = y0;
        while (at(t0 - 1, mid) && y0 - t0 < 12) {
          t0--;
        }
        while (at(t1 + 1, mid) && t1 - y0 < 12) {
          t1++;
        }
        final thick = t1 - t0 + 1;
        if (thick > math.max(8, w * 0.008)) continue;
        final center = (t0 + t1) / 2;
        var sumPos = 0.0, n = 0;
        int trace(int dir) {
          var y = center.round(), x = dir > 0 ? e0 : s0 - 1, gap = 0, last = dir > 0 ? e0 - 1 : s0;
          while (x >= 0 && x < minor) {
            int? best;
            for (final d in const [0, -1, 1, -2, 2]) {
              if (at(y + d, x)) {
                best = y + d;
                break;
              }
            }
            if (best != null) {
              y = best;
              gap = 0;
              last = x;
              sumPos += y;
              n++;
              visit(y, x);
            } else if (++gap > 6) {
              break;
            }
            x += dir;
          }
          return last;
        }

        for (var x = s0; x < e0; x++) {
          visit(y0, x);
          sumPos += center;
          n++;
        }
        final b = trace(1), a = trace(-1);
        if (b - a + 1 < minLen) continue;
        // Remember the traced pixels (the line is not perfectly straight).
        for (var x = a; x <= b; x++) {
          for (var l = math.max(0, center.round() - 14); l <= math.min(major - 1, center.round() + 14); l++) {
            final i = horizontal ? l * w + x : x * w + l;
            if (visited[i] == 1) lineMask![i] = 1;
          }
        }
        rules.add(_Rule(horizontal, sumPos / n, a.toDouble(), b + 1.0, thick.toDouble()));
      }
      // Join collinear pieces (lines broken by gaps wider than the tracer's).
      final posTol = w * 0.012, gapTol = w * 0.03;
      var list = rules;
      var changed = true;
      while (changed) {
        changed = false;
        list.sort((x, y) => x.pos.compareTo(y.pos));
        outer:
        for (var i = 0; i < list.length; i++) {
          for (var j = i + 1; j < list.length && list[j].pos - list[i].pos <= posTol; j++) {
            final a = list[i], b = list[j];
            final gap = math.max(a.a, b.a) - math.min(a.b, b.b);
            final sequential = -gap < math.min(a.length, b.length) * 0.15;
            if (gap <= gapTol && sequential) {
              final la = a.length, lb = b.length;
              a
                ..pos = (a.pos * la + b.pos * lb) / math.max(1, la + lb)
                ..a = math.min(a.a, b.a)
                ..b = math.max(a.b, b.b)
                ..thickness = math.max(a.thickness, b.thickness);
              list.removeAt(j);
              changed = true;
              break outer;
            }
          }
        }
      }
      out.addAll(list);
    }
    return out;
  }

  // ---- graphics -----------------------------------------------------------

  /// Non-text regions (QR codes, seals, stamps, signatures, logos): ink that
  /// is not covered by confidently recognised black text or ruling lines.
  List<(Rect, GraphicKind)> _graphics(List<_Rule> rules, List<PdfWord> words, List<Rect> shades) {
    final mask = Uint8List.fromList(faint);
    for (final sh in shades) {
      _clear(mask, sh.inflate(2));
    }
    for (final wd in words) {
      if (!_looksLikeText(wd)) continue;
      _clear(mask, wd.box.inflate(2));
    }
    final lm = lineMask;
    if (lm != null) {
      for (var i = 0; i < w * h; i++) {
        if (lm[i] == 1) mask[i] = 0;
      }
    }
    // Components on a coarse grid (merges strokes of one graphic).
    final cell = math.max(3, (w / 160).round());
    final gw = (w / cell).ceil(), gh = (h / cell).ceil();
    final cnt = Uint16List(gw * gh), col = Uint16List(gw * gh);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (mask[i] == 1) {
          final gi = (y ~/ cell) * gw + x ~/ cell;
          cnt[gi]++;
          if (colored[i] == 1) col[gi]++;
        }
      }
    }
    final on = Uint8List(gw * gh);
    final minInk = math.max(2, cell * cell ~/ 12);
    for (var i = 0; i < on.length; i++) {
      if (cnt[i] >= minInk) on[i] = 1;
    }
    // Dilate by two cells.
    final dil = Uint8List(gw * gh);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        if (on[y * gw + x] == 0) continue;
        for (var yy = math.max(0, y - 2); yy <= math.min(gh - 1, y + 2); yy++) {
          for (var xx = math.max(0, x - 2); xx <= math.min(gw - 1, x + 2); xx++) {
            dil[yy * gw + xx] = 1;
          }
        }
      }
    }
    final seen = Uint8List(gw * gh);
    final comps = <_Comp>[];
    for (var i = 0; i < dil.length; i++) {
      if (dil[i] == 0 || seen[i] == 1) continue;
      final c = _Comp(gw, gh, 0, 0);
      final stack = [i];
      seen[i] = 1;
      while (stack.isNotEmpty) {
        final k = stack.removeLast();
        final x = k % gw, y = k ~/ gw;
        c.x0 = math.min(c.x0, x);
        c.y0 = math.min(c.y0, y);
        c.x1 = math.max(c.x1, x);
        c.y1 = math.max(c.y1, y);
        c.ink += cnt[k];
        c.colored += col[k];
        for (final n in [k - 1, k + 1, k - gw, k + gw]) {
          if (n < 0 || n >= dil.length || seen[n] == 1 || dil[n] == 0) continue;
          if ((n == k - 1 && x == 0) || (n == k + 1 && x == gw - 1)) continue;
          seen[n] = 1;
          stack.add(n);
        }
      }
      comps.add(c);
    }
    final out = <(Rect, GraphicKind)>[];
    for (final c in comps) {
      // Back to pixels, removing the dilation margin.
      var r = Rect.fromLTRB((c.x0 + 2.0) * cell, (c.y0 + 2.0) * cell, (c.x1 - 1.0) * cell, (c.y1 - 1.0) * cell).intersect(Offset.zero & Size(w.toDouble(), h.toDouble()));
      if (r.width <= 0 || r.height <= 0) continue;
      r = _tighten(r, mask);
      final minSide = w * 0.045;
      if (r.width < minSide || r.height < minSide) continue;
      if (r.width > w * 0.9 && r.height > h * 0.9) continue;
      final density = _inkIn(r, mask) / (r.width * r.height);
      final colouredShare = c.ink == 0 ? 0.0 : c.colored / c.ink;
      // Edges of the paper and fold shadows: long thin strips at the border.
      final atEdge = r.left < w * 0.02 || r.top < h * 0.01 || r.right > w * 0.98 || r.bottom > h * 0.99;
      if (atEdge && (r.width < w * 0.06 || r.height < h * 0.04) && colouredShare < 0.3) continue;
      final aspect = r.width / r.height;
      var covered = 0.0;
      for (final wd in words) {
        final i = wd.box.intersect(r);
        if (i.width > 0 && i.height > 0) covered += i.width * i.height;
      }
      final textual = covered > r.width * r.height * 0.45;
      if (debug != null && r.width > w * 0.03 && r.height > w * 0.03) debug!('comp ${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()} dens=${density.toStringAsFixed(3)} col=${colouredShare.toStringAsFixed(2)} textual=$textual', Uint8List(0));
      if (textual && !(density > 0.3 && aspect > 0.8 && aspect < 1.25)) continue;
      GraphicKind kind;
      if (density > 0.3 && aspect > 0.8 && aspect < 1.25 && colouredShare < 0.2) {
        kind = GraphicKind.qrCode;
      } else if (colouredShare > 0.35) {
        kind = density < 0.12 && aspect > 1.4 ? GraphicKind.signature : GraphicKind.stamp;
      } else if (density < 0.02) {
        continue; // faint specks
      } else {
        kind = GraphicKind.graphic;
      }
      out.add((r, kind));
    }
    // Merge overlapping or touching graphics (a stamp and the signature over it).
    var merged = true;
    while (merged) {
      merged = false;
      for (var i = 0; i < out.length && !merged; i++) {
        for (var j = i + 1; j < out.length && !merged; j++) {
          if (out[i].$1.inflate(w * 0.01).overlaps(out[j].$1)) {
            final k = out[i].$2 == GraphicKind.qrCode || out[j].$2 == GraphicKind.qrCode ? GraphicKind.graphic : GraphicKind.stamp;
            out[i] = (out[i].$1.expandToInclude(out[j].$1), k);
            out.removeAt(j);
            merged = true;
          }
        }
      }
    }
    return out;
  }

  /// Removes typical OCR artefacts of borders and noise: unmatched
  /// brackets or bars at a word's ends (table and box edges read as
  /// characters) and tokens without letters or digits read with low
  /// confidence. Returns null when nothing real is left.
  static PdfWord? _cleanWord(PdfWord o) {
    var t = o.text.trim();
    if (t.isEmpty) return null;
    final conf = o.confidence ?? 0.8;
    var box = o.box;
    final per = box.width / math.max(1, t.length);
    while (t.length > 1 && (t.startsWith('|') || (t.startsWith('[') && !t.contains(']')))) {
      t = t.substring(1);
      box = Rect.fromLTRB(box.left + per, box.top, box.right, box.bottom);
    }
    while (t.length > 1 && (t.endsWith('|') || (t.endsWith(']') && !t.contains('[')))) {
      t = t.substring(0, t.length - 1);
      box = Rect.fromLTRB(box.left, box.top, box.right - per, box.bottom);
    }
    final alnum = t.replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097F₹$€£%]'), '').length;
    if (t == '|' || (alnum == 0 && conf < 0.75 && t != ':' && t != '-')) return null;
    if (alnum <= 2 && conf < 0.35) return null;
    return PdfWord(t, box, confidence: o.confidence);
  }

  /// After stray border characters were removed from a word, its box is
  /// trimmed to the ink that remains: the first (or last) group of ink
  /// columns is dropped when it is separated from the rest by a gap.
  PdfWord _trimToInk(PdfWord orig, PdfWord cleaned) {
    if (cleaned.text == orig.text.trim()) return cleaned;
    final b = orig.box;
    final x0 = math.max(0, b.left.floor()), x1 = math.min(w, b.right.ceil());
    final y0 = math.max(0, b.top.floor()), y1 = math.min(h, b.bottom.ceil());
    final lm = lineMask;
    final cols = <bool>[
      for (var x = x0; x < x1; x++)
        () {
          for (var y = y0; y < y1; y++) {
            final i = y * w + x;
            if (ink[i] == 1 && (lm == null || lm[i] == 0)) return true;
          }
          return false;
        }(),
    ];
    // Ink runs (letters) along the box.
    final runs = <(int, int)>[];
    var start = -1;
    for (var i = 0; i <= cols.length; i++) {
      final on = i < cols.length && cols[i];
      if (on && start < 0) start = i;
      if (!on && start >= 0) {
        runs.add((start, i));
        start = -1;
      }
    }
    if (runs.isEmpty) return cleaned;
    final gaps = [for (var i = 1; i < runs.length; i++) runs[i].$1 - runs[i - 1].$2]..sort();
    final typical = gaps.isEmpty ? 0 : gaps[gaps.length ~/ 2];
    bool bar((int, int) r) => r.$2 - r.$1 <= math.max(3, b.height * 0.12);
    final o = orig.text.trim();
    var first = 0, last = runs.length - 1;
    if ((o.startsWith('[') || o.startsWith('|')) && runs.length > 1 && bar(runs[0]) && runs[1].$1 - runs[0].$2 > typical * 1.5) first = 1;
    if ((o.endsWith(']') || o.endsWith('|')) && runs.length > 1 && bar(runs[last]) && runs[last].$1 - runs[last - 1].$2 > typical * 1.5) last--;
    final left = x0 + runs[first].$1.toDouble(), right = x0 + runs[last].$2.toDouble();
    if (right - left < b.width * 0.2) return cleaned;
    return PdfWord(cleaned.text, Rect.fromLTRB(left, b.top, right, b.bottom), confidence: cleaned.confidence);
  }

  /// A recognised word that is real printed text (not OCR noise on a
  /// stamp, signature or QR code).
  bool _looksLikeText(PdfWord wd) {
    final conf = wd.confidence ?? 0.8;
    final alnum = wd.text.replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097F]'), '').length;
    if (_coloredShare(wd.box) > 0.4) return false;
    return (conf >= 0.3 && alnum >= 2) || conf >= 0.8;
  }

  Rect _tighten(Rect r, Uint8List mask) {
    var x0 = r.right.toInt(), y0 = r.bottom.toInt(), x1 = r.left.toInt(), y1 = r.top.toInt();
    for (var y = r.top.toInt(); y < r.bottom.toInt(); y++) {
      for (var x = r.left.toInt(); x < r.right.toInt(); x++) {
        if (mask[y * w + x] == 1) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    if (x1 < x0) return r;
    return Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0);
  }

  void _clear(Uint8List m, Rect r) {
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    for (var y = y0; y < y1; y++) {
      m.fillRange(y * w + x0, y * w + math.max(x0, x1), 0);
    }
  }

  int _inkIn(Rect r, Uint8List m) {
    var n = 0;
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        n += m[y * w + x];
      }
    }
    return n;
  }

  double _coloredShare(Rect r) {
    final i = _inkIn(r, ink);
    return i == 0 ? 0 : _inkIn(r, colored) / i;
  }

  LGraphic _crop(Rect r, GraphicKind kind) {
    final pad = (w * 0.006).roundToDouble();
    final c = r.inflate(pad).intersect(Offset.zero & Size(w.toDouble(), h.toDouble()));
    final x0 = c.left.floor(), y0 = c.top.floor(), cw = c.width.ceil(), ch = c.height.ceil();
    final out = img.Image(width: cw, height: ch, numChannels: 3);
    final d = clean.data;
    for (var y = 0; y < ch; y++) {
      for (var x = 0; x < cw; x++) {
        final sx = math.min(w - 1, x0 + x), sy = math.min(h - 1, y0 + y);
        final j = (sy * w + sx) * 3;
        if (kind == GraphicKind.qrCode) {
          // Crisp black and white modules scan best.
          final v = norm[sy * w + sx] < 150 ? 0 : 255;
          out.setPixelRgb(x, y, v, v, v);
        } else {
          out.setPixelRgb(x, y, d[j], d[j + 1], d[j + 2]);
        }
      }
    }
    return LGraphic(mapRect(Rect.fromLTWH(x0.toDouble(), y0.toDouble(), cw.toDouble(), ch.toDouble())), Uint8List.fromList(img.encodePng(out, level: 6)), 'png', cw, ch,
        kind: kind);
  }

  // ---- text styling -------------------------------------------------------

  /// Bold from stroke width; underline from rules just below a word.
  List<LWordPx> _styleWords(List<PdfWord> words, List<_Rule> rules) {
    final strokes = <double>[];
    final out = <LWordPx>[];
    // Stroke width relative to the font size (fitted from the word's width,
    // which unlike its height doesn't depend on capitals or descenders).
    double rel(LWordPx x) => x.stroke / math.max(1, _sizePx(x.word));
    for (final wd in words) {
      final x = LWordPx(wd, _strokeWidth(wd.box));
      out.add(x);
      if (x.stroke > 0 && wd.text.length >= 2) strokes.add(rel(x));
    }
    final base = median(strokes);
    if (debug != null) {
      debug!('bold base=${base.toStringAsFixed(3)} ${out.map((x) => '${x.word.text}=${(rel(x) / base).toStringAsFixed(2)}').join(' ')}', Uint8List(0));
    }
    for (final x in out) {
      x.bold = base > 0 && rel(x) > base * 1.22;
    }
    return out;
  }

  /// Underlines, found in the ink: a nearly continuous ink row at the
  /// bottom of a word or just below it. The full run must stay within its
  /// text row (a table border running past the text is not an underline).
  void _markUnderlines(List<_Row> rows, List<_Rule> rules) {
    for (final row in rows) {
      final hs = row.words.map((x) => x.word.box.height).toList()..sort();
      final lh = hs[hs.length ~/ 2];
      final rb = row.box;
      final reach = math.max(w * 0.03, lh * 1.5);
      for (final x in row.words) {
        final b = x.word.box;
        if (b.width < 4) continue;
        final y0 = (b.top + b.height * 0.55).round(), y1 = math.min(h - 1, (b.bottom + lh * 0.6).round());
        for (var y = math.max(0, y0); y <= y1; y++) {
          // Longest ink run on this row that overlaps the word.
          bool on(int xx) {
            for (var d = -1; d <= 1; d++) {
              final yy = y + d;
              if (yy >= 0 && yy < h && ink[yy * w + xx] == 1) return true;
            }
            return false;
          }

          var bestLen = 0, bestA = 0, bestB = 0;
          var xx = math.max(0, b.left.round());
          while (xx < math.min(w, b.right.round())) {
            if (!on(xx)) {
              xx++;
              continue;
            }
            var a = xx, e = xx;
            // Extend in both directions (a run may continue past the word).
            while (a > 0 && (on(a - 1) || (a > 2 && on(a - 2) && on(a - 3)))) {
              a--;
            }
            while (e < w - 1) {
              if (on(e + 1)) {
                e++;
              } else if (e + 2 < w && on(e + 2)) {
                e += 2;
              } else {
                break;
              }
            }
            final int covered = math.min(e, b.right.round()) - math.max(a, b.left.round());
            if (covered > bestLen) {
              bestLen = covered;
              bestA = a;
              bestB = e;
            }
            xx = e + 1;
          }
          // A traced ruling line at this height that runs past the text (a
          // table or box border) is not an underline.
          final border = rules.any((r) => r.horizontal && (r.pos - y).abs() <= 4 && r.a <= b.right && r.b >= b.left && (r.a < rb.left - reach || r.b > rb.right + reach));
          if (!border && bestLen >= b.width * 0.85 && bestA >= rb.left - reach && bestB <= rb.right + reach) {
            x.underline = true;
            break;
          }
        }
      }
    }
  }

  /// Font size of a word in pixels, from its width (checked against height).
  static double _sizePx(PdfWord wd) {
    final adv = textAdvance(wd.text) - 0.07;
    final byWidth = adv <= 0 ? 0.0 : wd.box.width / adv;
    final byHeight = wd.box.height / 0.8;
    return byWidth <= 0 ? byHeight : clampD(byWidth, byHeight * 0.6, byHeight * 1.6);
  }

  /// Within a run of words (a segment), a clear majority decides bold, so
  /// noisy stroke estimates don't make lines partly bold; genuinely mixed
  /// runs keep their per-word weights.
  static void _smoothBold(List<LWordPx> words) {
    if (words.length < 2) return;
    var bold = 0, all = 0;
    for (final x in words) {
      final n = x.word.text.length;
      all += n;
      if (x.bold) bold += n;
    }
    final f = bold / math.max(1, all);
    if (f >= 0.65) {
      for (final x in words) {
        x.bold = true;
      }
    } else if (f <= 0.35) {
      for (final x in words) {
        x.bold = false;
      }
    }
  }

  /// Average stroke width inside a word box, to a fraction of a pixel:
  /// the ink "mass" of each row (from gray levels, so anti-aliased edges
  /// count partly) divided by the number of strokes crossing it.
  double _strokeWidth(Rect r) {
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, (r.top + r.height * 0.25).floor()), y1 = math.min(h, (r.bottom - r.height * 0.25).ceil());
    var mass = 0.0, runs = 0;
    for (var y = y0; y < y1; y++) {
      var inRun = false;
      for (var x = x0; x < x1; x++) {
        final n = norm[y * w + x];
        if (n < 225) mass += math.min(1.0, (225 - n) / 145);
        final on = n < 150;
        if (on && !inRun) runs++;
        inRun = on;
      }
    }
    return runs == 0 ? 0 : mass / runs;
  }

  // ---- rows ---------------------------------------------------------------

  /// Groups words into text rows. Words are chained left to right: a word
  /// joins the row whose last word overlaps it vertically, so lines that
  /// tilt or curve in a photo stay single rows and never swallow the line
  /// above or below.
  List<_Row> _rows(List<LWordPx> words) {
    final sorted = [...words]..sort((a, b) => a.word.box.left.compareTo(b.word.box.left));
    final rows = <_Row>[];
    for (final wd in sorted) {
      final b = wd.word.box;
      _Row? best;
      var bestScore = 0.0;
      for (final r in rows) {
        final last = r.words.last.word.box;
        if (b.left < last.left) continue;
        final ov = math.min(last.bottom, b.bottom) - math.max(last.top, b.top);
        final score = ov / math.min(last.height, b.height);
        if (score > 0.5 && score > bestScore) {
          best = r;
          bestScore = score;
        }
      }
      if (best == null) {
        rows.add(_Row([wd]));
      } else {
        best.words.add(wd);
      }
    }
    rows.sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));
    return rows;
  }

  // ---- tables -------------------------------------------------------------

  List<(LTable, List<_Row>)> _tables(List<_Rule> rules, List<_Row> rows) {
    final hs = rules.where((r) => r.horizontal && r.length > w * 0.12).toList();
    final vs = rules.where((r) => !r.horizontal && r.length > h * 0.015).toList();
    final tol = w * 0.012;
    if (debug != null) {
      debug!('H ${hs.map((r) => '${r.pos.round()}:${r.a.round()}-${r.b.round()}').join(' ')}', Uint8List(0));
      debug!('V ${vs.where((r) => r.pos > w * 0.02 && r.length > h * 0.02).map((r) => '${r.pos.round()}:${r.a.round()}-${r.b.round()}').join(' ')}', Uint8List(0));
    }
    bool touch(_Rule a, _Rule b) {
      final hr = a.horizontal ? a : b, vr = a.horizontal ? b : a;
      return vr.pos >= hr.a - tol && vr.pos <= hr.b + tol && hr.pos >= vr.a - tol && hr.pos <= vr.b + tol;
    }

    // Groups of connected horizontal and vertical rules.
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
    final out = <(LTable, List<_Row>)>[];
    for (var gi = 0; gi < next; gi++) {
      final gh = [for (var i = 0; i < all.length; i++) if (group[i] == gi && all[i].horizontal) all[i]];
      final gv = [for (var i = 0; i < all.length; i++) if (group[i] == gi && !all[i].horizontal) all[i]];
      if (gh.length < 2 || gv.length < 2) continue;
      final ys = _cluster(gh.map((r) => r.pos).toList(), h * 0.012);
      var xs = _cluster(gv.map((r) => r.pos).toList(), w * 0.022);
      // A real column border never runs through a word or a normal gap
      // between words of one phrase ("Amount | Payable").
      if (ys.length >= 2 && xs.length > 2) {
        final top = ys.first, bottom = ys.last;
        bool cuts(double x) {
          for (final row in rows) {
            final rb = row.box;
            if (rb.center.dy < top || rb.center.dy > bottom) continue;
            final wh = median(row.words.map((x) => x.word.box.height));
            for (var i = 0; i < row.words.length; i++) {
              final b = row.words[i].word.box;
              if (x > b.left + b.width * 0.2 && x < b.right - b.width * 0.2) return true;
              if (i + 1 < row.words.length) {
                final n = row.words[i + 1].word.box;
                if (x > b.right && x < n.left && n.left - b.right < wh * 0.9) return true;
              }
            }
          }
          return false;
        }

        xs = [xs.first, for (var i = 1; i < xs.length - 1; i++) if (!cuts(xs[i])) xs[i], xs.last];
      }
      if (ys.length < 2 || xs.length < 2) continue;
      final box = Rect.fromLTRB(xs.first, ys.first, xs.last, ys.last);
      if (debug != null) debug!('table xs=$xs ys=$ys', Uint8List(0));
      if (box.width < w * 0.2 || box.height < h * 0.02) continue;
      final nr = ys.length - 1, nc = xs.length - 1;
      bool vBorder(int r, int c) => gv.any((v) => (v.pos - xs[c]).abs() < w * 0.022 && v.a <= ys[r] + (ys[r + 1] - ys[r]) * 0.35 && v.b >= ys[r + 1] - (ys[r + 1] - ys[r]) * 0.35);
      bool hBorder(int r, int c) => gh.any((x) => (x.pos - ys[r]).abs() < h * 0.012 && x.a <= xs[c] + (xs[c + 1] - xs[c]) * 0.35 && x.b >= xs[c + 1] - (xs[c + 1] - xs[c]) * 0.35);
      // Cells, merging across missing borders.
      final owner = List.generate(nr, (_) => List<LCell?>.filled(nc, null));
      final cells = <LCell>[];
      for (var r = 0; r < nr; r++) {
        for (var c = 0; c < nc; c++) {
          if (owner[r][c] != null) continue;
          var span = 1;
          while (c + span < nc && !vBorder(r, c + span)) {
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
      // Assign text rows to cells.
      final used = <_Row>[];
      final cellWords = <LCell, List<LWordPx>>{};
      for (final row in rows) {
        final c = row.box.center;
        if (!box.contains(c)) continue;
        used.add(row);
        for (final wd in row.words) {
          final p = wd.word.box.center;
          var ci = 0, ri = 0;
          while (ci < nc - 1 && p.dx > xs[ci + 1]) {
            ci++;
          }
          while (ri < nr - 1 && p.dy > ys[ri + 1]) {
            ri++;
          }
          final cell = owner[ri][ci]!;
          (cellWords[cell] ??= []).add(wd);
        }
      }
      // Map geometry to points (the table is treated as axis-aligned).
      final pbox = mapRect(box);
      final kx = pbox.width / box.width, ky = pbox.height / box.height;
      final colX = [for (final x in xs) pbox.left + (x - box.left) * kx];
      final rowY = [for (final y in ys) pbox.top + (y - box.top) * ky];
      for (final e in cellWords.entries) {
        for (final r in _rows(e.value)) {
          e.key.lines.add(_toLine(r.words));
        }
      }
      final tablePaper = _paperLevel(box.inflate(h * 0.03));
      for (final cell in cells) {
        final rect = Rect.fromLTRB(xs[cell.col], ys[cell.row], xs[cell.col + cell.colSpan], ys[cell.row + cell.rowSpan]);
        cell.shade = _stepShaded(rect) ? _fill(rect.deflate(math.max(3, w * 0.004)), tablePaper, 14) : null;
      }
      final thickness = median([...gh, ...gv].map((r) => r.thickness)) * scaleAt(box);
      out.add((LTable(colX, rowY, cells, borderWidth: clampD(thickness, 0.5, 3)), used));
    }
    return out;
  }

  /// Whether a cell is filled: clearly darker than the area just across at
  /// least two of its borders. A lighting gradient in a photo changes
  /// smoothly and has no such step.
  bool _stepShaded(Rect cell) {
    final s = math.max(6.0, w * 0.015), m = math.max(4.0, w * 0.005);
    var steps = 0;
    for (final (inside, out) in [
      (Rect.fromLTRB(cell.left + m, cell.top + m, cell.left + m + s, cell.bottom - m), Rect.fromLTRB(cell.left - m - s, cell.top + m, cell.left - m, cell.bottom - m)),
      (Rect.fromLTRB(cell.right - m - s, cell.top + m, cell.right - m, cell.bottom - m), Rect.fromLTRB(cell.right + m, cell.top + m, cell.right + m + s, cell.bottom - m)),
      (Rect.fromLTRB(cell.left + m, cell.top + m, cell.right - m, cell.top + m + s), Rect.fromLTRB(cell.left + m, cell.top - m - s, cell.right - m, cell.top - m)),
      (Rect.fromLTRB(cell.left + m, cell.bottom - m - s, cell.right - m, cell.bottom - m), Rect.fromLTRB(cell.left + m, cell.bottom + m, cell.right - m, cell.bottom + m + s)),
    ]) {
      final a = _behind(inside), b = _behind(out);
      if (a < 255 && b < 255 && b - a >= 14) steps++;
    }
    return steps >= 2;
  }

  static List<double> _cluster(List<double> v, double tol) {
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

  /// A fill colour when the non-ink area of [r] is clearly darker than the
  /// paper level [paper] (raw gray). The colour is scaled so that paper
  /// would be white.
  int? _fill(Rect r, [double? paper, double minDelta = 14]) {
    if (r.width < 2 || r.height < 2) return null;
    final ref = paper ?? _globalPaper;
    var n = 0, sr = 0, sg = 0, sb = 0, sum = 0;
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    final d = im.data;
    for (var y = y0; y < y1; y += 2) {
      for (var x = x0; x < x1; x += 2) {
        final i = y * w + x;
        if (ink[i] == 1 || outside[i] == 1) continue;
        n++;
        sum += raw[i];
        sr += d[i * 3];
        sg += d[i * 3 + 1];
        sb += d[i * 3 + 2];
      }
    }
    if (n < 20) return null;
    final mean = sum / n;
    if (mean > ref - minDelta) return null;
    final k = 255 / math.max(1, ref);
    int c(int v) => clamp255(v / n * k);
    return 0xFF000000 | (c(sr) << 16) | (c(sg) << 8) | c(sb);
  }

  late final double _globalPaper = _paperLevel(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));

  // ---- shaded bands -------------------------------------------------------

  /// Grey or coloured bars behind a text line (e.g. a section heading).
  /// Median raw gray of non-ink paper pixels in [r] (255 when none).
  double _paperLevel(Rect r) {
    final vals = <int>[];
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    final step = math.max(1, ((x1 - x0) * (y1 - y0) / 4000).floor());
    var k = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        if (k++ % step != 0) continue;
        final i = y * w + x;
        if (ink[i] == 0 && outside[i] == 0 && faint[i] == 0) vals.add(raw[i]);
      }
    }
    if (vals.length < 8) return 255;
    vals.sort();
    return vals[vals.length ~/ 2].toDouble();
  }

  /// Raw gray of the background behind [r], ignoring ink (255 when none).
  double _behind(Rect r) {
    final vals = <int>[];
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = y * w + x;
        if (ink[i] == 0 && outside[i] == 0) vals.add(raw[i]);
      }
    }
    if (vals.length < 8) return 255;
    vals.sort();
    return vals[vals.length ~/ 2].toDouble();
  }

  /// Grey or coloured bars behind a text line (e.g. a section heading). The
  /// background beside the text is compared with the paper above and below
  /// it, so lighting gradients in photos don't count as shading.
  List<(Rect, int)> _shades(List<_Row> rows) {
    final out = <(Rect, int)>[];
    for (final r in rows) {
      final hs = r.words.map((x) => x.word.box.height).toList()..sort();
      final lh = hs[hs.length ~/ 2];
      final tops = r.words.map((x) => x.word.box.top).toList()..sort();
      final top = tops[tops.length ~/ 2];
      final b = Rect.fromLTRB(r.box.left, top, r.box.right, top + lh);
      final probe = w * 0.03;
      final left = _behind(Rect.fromLTRB(b.left - probe, b.top + lh * 0.2, b.left - 3, b.bottom - lh * 0.2));
      if (debug != null && r.words.length > 2) {
        debug!('shade ${r.words.map((x) => x.word.text).take(3).join(' ')} L=$left R=${_behind(Rect.fromLTRB(b.right + 3, b.top + lh * 0.2, b.right + probe, b.bottom - lh * 0.2))} A=${_paperLevel(Rect.fromLTRB(b.left, b.top - lh * 3.2, b.right, b.top - lh * 2.2))} B=${_paperLevel(Rect.fromLTRB(b.left, b.bottom + lh * 2.2, b.right, b.bottom + lh * 3.2))}', Uint8List(0));
      }
      final right = _behind(Rect.fromLTRB(b.right + 3, b.top + lh * 0.2, b.right + probe, b.bottom - lh * 0.2));
      final above = _paperLevel(Rect.fromLTRB(b.left, b.top - lh * 3.2, b.right, b.top - lh * 2.2));
      final below = _paperLevel(Rect.fromLTRB(b.left, b.bottom + lh * 2.2, b.right, b.bottom + lh * 3.2));
      final paper = math.max(above == 255 ? 0.0 : above, below == 255 ? 0.0 : below);
      if (paper == 0) continue;
      if (left > paper - 16 || right > paper - 16) continue;
      final level = (left + right) / 2;
      final limit = math.max((level + paper) / 2, paper - 9);
      bool shaded(double x, double y) => _behind(Rect.fromCenter(center: Offset(x, y), width: 5, height: 5)) < limit;
      // Extend sideways and vertically until paper is reached.
      final cy = b.center.dy;
      var x0 = b.left - 3, x1 = b.right + 3;
      bool paperAt(double x) => outside[cy.round().clamp(0, h - 1) * w + x.round().clamp(0, w - 1)] == 0;
      while (x0 > 3 && paperAt(x0 - 3) && shaded(x0 - 3, cy)) {
        x0 -= 3;
      }
      while (x1 < w - 4 && paperAt(x1 + 3) && shaded(x1 + 3, cy)) {
        x1 += 3;
      }
      final probeXs = [x0 + 6, (x0 + b.left) / 2, (x1 + b.right) / 2, x1 - 6];
      var y0 = b.top, y1 = b.bottom;
      while (y0 > 3 && probeXs.where((x) => shaded(x, y0 - 2)).length >= 3) {
        y0 -= 2;
      }
      while (y1 < h - 4 && probeXs.where((x) => shaded(x, y1 + 2)).length >= 3) {
        y1 += 2;
      }
      final band = Rect.fromLTRB(x0, y0, x1, y1);
      // A band is wider than its text and not taller than a few lines.
      if (band.width < b.width + w * 0.06 || band.height > lh * 4 || band.height < lh * 1.05) continue;
      final fill = _fill(band.deflate(3), paper);
      if (fill == null) continue;
      if (out.any((o) => o.$1.overlaps(band))) continue;
      out.add((band, fill));
    }
    return out;
  }

  // ---- words → page points ------------------------------------------------

  LLine _toLine(List<LWordPx> words) {
    // Segments: words separated by gaps wider than about a word height.
    final hs = words.map((x) => x.word.box.height).toList()..sort();
    final gapLimit = hs[hs.length ~/ 2] * 1.3;
    var seg = <LWordPx>[];
    for (final x in words) {
      if (seg.isNotEmpty && x.word.box.left - seg.last.word.box.right > gapLimit) {
        _smoothBold(seg);
        seg = [];
      }
      seg.add(x);
    }
    _smoothBold(seg);
    final ws = <LWord>[];
    for (final x in words) {
      final wd = x.word;
      final box = mapRect(wd.box);
      ws.add(LWord(wd.text, box,
          bold: x.bold,
          underline: x.underline,
          color: _inkColor(wd.box),
          confidence: wd.confidence,
          font: 'Arial'));
    }
    final line = LLine(ws);
    _fitSize(line);
    return line;
  }

  /// Text colour: black unless the ink is clearly coloured.
  int _inkColor(Rect r) {
    if (_coloredShare(r) < 0.6) return 0xFF000000;
    var n = 0, sr = 0, sg = 0, sb = 0;
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = y * w + x;
        if (ink[i] == 0) continue;
        n++;
        sr += clean.data[i * 3];
        sg += clean.data[i * 3 + 1];
        sb += clean.data[i * 3 + 2];
      }
    }
    if (n == 0) return 0xFF000000;
    return 0xFF000000 | ((sr ~/ n) << 16) | ((sg ~/ n) << 8) | (sb ~/ n);
  }

  /// Font size from the measured width of the words (a font of the right
  /// size reproduces the line length), checked against their height.
  static void _fitSize(LLine l) {
    // Single punctuation marks have unreliable boxes; leave them out.
    final words = l.words.where((w) => w.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').isNotEmpty && (w.confidence ?? 1) >= 0.3).toList();
    if (words.isEmpty) {
      // Nothing reliable to measure: the page's common size is used.
      for (final wd in l.words) {
        wd.size = 0;
      }
      return;
    }
    final use = words;
    var ink = 0.0, adv = 0.0, chars = 0;
    for (final wd in use) {
      ink += wd.box.width;
      adv += textAdvance(wd.text, bold: wd.bold) - 0.07; // side bearings
      chars += wd.text.length;
    }
    final byWidth = adv <= 0 ? 0.0 : ink / adv;
    // Height of capitals/ascenders ≈ 0.72 em; with descenders ≈ 0.93 em.
    final hs = <double>[];
    for (final wd in use) {
      final t = wd.text;
      final desc = RegExp(r'[gjpqy,;()\[\]{}@$]').hasMatch(t);
      final asc = RegExp(r'[A-Z0-9bdfhklt/\\|!?:]').hasMatch(t);
      if (!asc && !desc) {
        hs.add(wd.box.height / 0.53); // x-height
      } else {
        hs.add(wd.box.height / (desc ? (asc ? 0.93 : 0.73) : 0.73));
      }
    }
    var byHeight = median(hs);
    // A box much taller than its width suggests was stretched (an underline
    // or a border below the word): its height is not used.
    if (byWidth > 0 && byHeight > byWidth * 1.3) byHeight = byWidth;
    var size = byWidth > 0 ? byWidth : byHeight;
    // Short text measures its width poorly: trust its height more.
    // Long text measures its width reliably (wide, heavy faces included).
    if (byHeight > 0) {
      size = chars < 8
          ? clampD(size, byHeight * 0.85, byHeight * 1.15)
          : chars < 16
              ? clampD(size, byHeight * 0.7, byHeight * 1.35)
              : clampD(size, byHeight * 0.65, byHeight * 1.6);
    }
    for (final wd in l.words) {
      wd.size = size;
    }
  }

  /// Snaps nearly equal font sizes on the page to one value each so the
  /// rebuilt page has consistent typography.
  static void _harmoniseSizes(LayoutPage page) {
    final lines = [
      ...page.lines,
      for (final t in page.tables)
        for (final c in t.cells) ...c.lines,
    ];
    final sizes = lines.map((l) => l.size).where((v) => v > 0).toList()..sort();
    if (sizes.isEmpty) return;
    final groups = <List<double>>[];
    for (final s in sizes) {
      if (groups.isNotEmpty && s <= groups.last.first * 1.09) {
        groups.last.add(s);
      } else {
        groups.add([s]);
      }
    }
    final centers = [for (final g in groups) halfPoint(median(g))];
    // The size most text on the page uses (by characters).
    final weight = <double, int>{};
    for (final l in lines) {
      if (l.size <= 0) continue;
      var best = centers.first;
      for (final c in centers) {
        if ((c - l.size).abs() < (best - l.size).abs()) best = c;
      }
      weight[best] = (weight[best] ?? 0) + l.text.length;
    }
    final common = weight.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    for (final l in lines) {
      // Lines read with very low confidence have unreliable boxes.
      if (l.size <= 0) {
        for (final wd in l.words) {
          wd.size = common;
        }
        continue;
      }
      var best = centers.first;
      for (final c in centers) {
        if ((c - l.size).abs() < (best - l.size).abs()) best = c;
      }
      for (final wd in l.words) {
        wd.size = best;
      }
    }
  }
}

class LWordPx {
  final PdfWord word;
  final double stroke;
  bool bold = false;
  bool underline = false;
  LWordPx(this.word, this.stroke);
}

class _Row {
  final List<LWordPx> words;
  _Row(this.words);
  Rect get box => words.map((w) => w.word.box).reduce((a, b) => a.expandToInclude(b));
}
