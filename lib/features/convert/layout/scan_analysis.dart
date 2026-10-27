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
    final rules = _rules();
    final words = [
      for (final o in ocr)
        if (o.text.trim().isNotEmpty) o,
    ];
    // Shaded bands first, so they are not taken for graphics.
    final preRows = _rows(_styleWords(words, rules));
    final shadeBoxes = _shades(preRows);
    final graphics = _graphics(rules, words, shadeBoxes.map((x) => x.$1).toList());
    final graphicRects = graphics.map((g) => g.$1).toList();
    // Text that belongs to a graphic (stamp text, handwriting read as text).
    final textWords = words.where((wd) {
      final c = wd.box.center;
      for (final r in graphicRects) {
        if (r.contains(c)) return false;
      }
      return true;
    }).toList();
    final styled = _styleWords(textWords, rules);
    final rows = _rows(styled);
    final tables = _tables(rules, rows);
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
      if (sat > 45 && n < 225) {
        colored[i] = 1;
        ink[i] = 1;
      }
      if (n < 212) faint[i] = 1;
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
    final outside = Uint8List.fromList(out);
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

  List<_Rule> _rules() {
    final minLen = math.max(24, (w * 0.035).round());
    final out = <_Rule>[];
    for (final horizontal in [true, false]) {
      final major = horizontal ? h : w, minor = horizontal ? w : h;
      final segs = <(int, int, int)>[]; // line index, start, end
      for (var y = 0; y < major; y++) {
        var start = -1, gap = 0;
        for (var x = 0; x <= minor; x++) {
          final on = x < minor && ink[horizontal ? y * w + x : x * w + y] == 1;
          if (on) {
            if (start < 0) start = x;
            gap = 0;
          } else if (start >= 0) {
            gap++;
            if (gap > 2 || x == minor) {
              final end = x - gap;
              if (end - start >= minLen) segs.add((y, start, end));
              start = -1;
              gap = 0;
            }
          }
        }
      }
      // Merge segments on adjacent lines into rules (allowing a slight tilt).
      final rules = <_Rule>[];
      for (final (y, a, b) in segs) {
        _Rule? hit;
        for (final r in rules.reversed) {
          if (y - (r.pos + r.thickness / 2) > 3) break;
          if (math.min(b, r.b) - math.max(a, r.a) > math.min(b - a, r.length) * 0.5) {
            hit = r;
            break;
          }
        }
        if (hit == null) {
          rules.add(_Rule(horizontal, y.toDouble(), a.toDouble(), b.toDouble(), 1));
        } else {
          final top = hit.pos - hit.thickness / 2 + 0.5;
          final nt = y - top + 1;
          hit
            ..thickness = nt
            ..pos = top + nt / 2 - 0.5
            ..a = math.min(hit.a, a.toDouble())
            ..b = math.max(hit.b, b.toDouble());
        }
      }
      // Thick blobs are filled shapes or bold text, not rules.
      out.addAll(rules.where((r) => r.thickness <= math.max(6, w * 0.006) && r.length >= minLen));
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
      if ((wd.confidence ?? 0.8) < 0.55 || _coloredShare(wd.box) > 0.4) continue;
      _clear(mask, wd.box.inflate(2));
    }
    for (final r in rules) {
      final t = r.thickness / 2 + 2;
      _clear(mask, r.horizontal ? Rect.fromLTRB(r.a - 2, r.pos - t, r.b + 2, r.pos + t) : Rect.fromLTRB(r.pos - t, r.a - 2, r.pos + t, r.b + 2));
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
      final density = _inkIn(r, ink) / (r.width * r.height);
      final colouredShare = c.ink == 0 ? 0.0 : c.colored / c.ink;
      // Edges of the paper and fold shadows: long thin strips at the border.
      final atEdge = r.left < w * 0.02 || r.top < h * 0.01 || r.right > w * 0.98 || r.bottom > h * 0.99;
      if (atEdge && (r.width < w * 0.06 || r.height < h * 0.04) && colouredShare < 0.3) continue;
      final aspect = r.width / r.height;
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
    for (final wd in words) {
      final sw = _strokeWidth(wd.box);
      out.add(LWordPx(wd, sw));
      if (sw > 0) strokes.add(sw / math.max(1, wd.box.height));
    }
    final base = median(strokes);
    for (final x in out) {
      final rel = x.stroke / math.max(1, x.word.box.height);
      x.bold = base > 0 && rel > base * 1.28;
      final b = x.word.box;
      for (final r in rules.where((r) => r.horizontal)) {
        final dy = r.pos - b.bottom;
        if (dy > -b.height * 0.15 && dy < b.height * 0.45) {
          final ov = math.min(r.b, b.right) - math.max(r.a, b.left);
          if (ov > b.width * 0.6 && r.length < w * 0.75) x.underline = true;
        }
      }
    }
    return out;
  }

  /// Median horizontal run length of ink inside a word box.
  double _strokeWidth(Rect r) {
    final runs = <int>[];
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, (r.top + r.height * 0.2).floor()), y1 = math.min(h, (r.bottom - r.height * 0.2).ceil());
    for (var y = y0; y < y1; y++) {
      var run = 0;
      for (var x = x0; x < x1; x++) {
        if (norm[y * w + x] < 150) {
          run++;
        } else if (run > 0) {
          runs.add(run);
          run = 0;
        }
      }
      if (run > 0) runs.add(run);
    }
    if (runs.isEmpty) return 0;
    runs.sort();
    return runs[runs.length ~/ 2].toDouble();
  }

  // ---- rows ---------------------------------------------------------------

  List<_Row> _rows(List<LWordPx> words) {
    final sorted = [...words]..sort((a, b) => a.word.box.center.dy.compareTo(b.word.box.center.dy));
    final rows = <_Row>[];
    for (final wd in sorted) {
      _Row? hit;
      for (final r in rows.reversed.take(3)) {
        final rb = r.box;
        final ov = math.min(rb.bottom, wd.word.box.bottom) - math.max(rb.top, wd.word.box.top);
        if (ov > math.min(rb.height, wd.word.box.height) * 0.45) {
          hit = r;
          break;
        }
      }
      if (hit == null) {
        rows.add(_Row([wd]));
      } else {
        hit.words.add(wd);
      }
    }
    for (final r in rows) {
      r.words.sort((a, b) => a.word.box.left.compareTo(b.word.box.left));
    }
    return rows;
  }

  // ---- tables -------------------------------------------------------------

  List<(LTable, List<_Row>)> _tables(List<_Rule> rules, List<_Row> rows) {
    final hs = rules.where((r) => r.horizontal && r.length > w * 0.12).toList();
    final vs = rules.where((r) => !r.horizontal && r.length > h * 0.015).toList();
    final tol = w * 0.012;
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
      final xs = _cluster(gv.map((r) => r.pos).toList(), w * 0.022);
      if (ys.length < 2 || xs.length < 2) continue;
      final box = Rect.fromLTRB(xs.first, ys.first, xs.last, ys.last);
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
      for (final cell in cells) {
        final rect = Rect.fromLTRB(xs[cell.col], ys[cell.row], xs[cell.col + cell.colSpan], ys[cell.row + cell.rowSpan]);
        cell.shade = _fill(rect.deflate(math.max(3, w * 0.004)));
      }
      final thickness = median([...gh, ...gv].map((r) => r.thickness)) * scaleAt(box);
      out.add((LTable(colX, rowY, cells, borderWidth: clampD(thickness, 0.5, 3)), used));
    }
    return out;
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

  /// A fill colour when the non-ink area of [r] is clearly darker than paper.
  int? _fill(Rect r) {
    if (r.width < 2 || r.height < 2) return null;
    var n = 0, sr = 0, sg = 0, sb = 0, sum = 0;
    final x0 = math.max(0, r.left.floor()), x1 = math.min(w, r.right.ceil());
    final y0 = math.max(0, r.top.floor()), y1 = math.min(h, r.bottom.ceil());
    final d = im.data;
    for (var y = y0; y < y1; y += 2) {
      for (var x = x0; x < x1; x += 2) {
        final i = y * w + x;
        if (ink[i] == 1) continue;
        n++;
        sum += norm[i];
        sr += d[i * 3];
        sg += d[i * 3 + 1];
        sb += d[i * 3 + 2];
      }
    }
    if (n < 20) return null;
    final mean = sum / n;
    if (mean > 226) return null;
    // Colour of the band relative to paper (corrected for illumination).
    final k = mean / math.max(1, (sr + sg + sb) / (3 * n));
    int c(int v) => clamp255(v / n * k);
    return 0xFF000000 | (c(sr) << 16) | (c(sg) << 8) | c(sb);
  }

  // ---- shaded bands -------------------------------------------------------

  /// Grey or coloured bars behind a text line (e.g. a section heading).
  List<(Rect, int)> _shades(List<_Row> rows) {
    final out = <(Rect, int)>[];
    for (final r in rows) {
      final b = r.box;
      final cy = b.center.dy.round();
      double sideLevel(int from, int to) {
        final vals = <int>[];
        for (var x = math.max(0, from); x < math.min(w, to); x++) {
          for (var y = math.max(0, cy - 2); y <= math.min(h - 1, cy + 2); y++) {
            final i = y * w + x;
            if (ink[i] == 0) vals.add(norm[i]);
          }
        }
        if (vals.length < 10) return 255;
        vals.sort();
        return vals[vals.length ~/ 2].toDouble();
      }

      final probe = (w * 0.03).round();
      final left = sideLevel(b.left.round() - probe, b.left.round() - 2);
      final right = sideLevel(b.right.round() + 2, b.right.round() + probe);
      if (left > 228 || right > 228) continue;
      final level = (left + right) / 2;
      bool shaded(int x, int y) {
        var n = 0, s = 0;
        for (var yy = math.max(0, y - 1); yy <= math.min(h - 1, y + 1); yy++) {
          for (var xx = math.max(0, x - 1); xx <= math.min(w - 1, x + 1); xx++) {
            final i = yy * w + xx;
            if (ink[i] == 0) {
              n++;
              s += norm[i];
            }
          }
        }
        return n > 0 && s / n < math.min(234, level + 14);
      }

      // Extend sideways and vertically until paper is reached.
      var x0 = b.left.round(), x1 = b.right.round();
      while (x0 > 0 && shaded(x0 - 3, cy)) {
        x0 -= 3;
      }
      while (x1 < w - 1 && shaded(x1 + 3, cy)) {
        x1 += 3;
      }
      final probeXs = [x0 + 6, (x0 + b.left.round()) ~/ 2, (x1 + b.right.round()) ~/ 2, x1 - 6];
      var y0 = b.top.round(), y1 = b.bottom.round();
      while (y0 > 0 && probeXs.where((x) => shaded(x, y0 - 2)).length >= 3) {
        y0 -= 2;
      }
      while (y1 < h - 1 && probeXs.where((x) => shaded(x, y1 + 2)).length >= 3) {
        y1 += 2;
      }
      final band = Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1.toDouble(), y1.toDouble());
      // A band is wider than its text and not taller than a few lines.
      if (band.width < b.width + w * 0.06 || band.height > b.height * 4 || band.height < b.height * 1.05) continue;
      final fill = _fill(band.deflate(2));
      if (fill == null) continue;
      if (out.any((o) => o.$1.overlaps(band))) continue;
      out.add((band, fill));
    }
    return out;
  }

  // ---- words → page points ------------------------------------------------

  LLine _toLine(List<LWordPx> words) {
    final ws = <LWord>[];
    for (final x in words) {
      final wd = x.word;
      final box = mapRect(wd.box);
      ws.add(LWord(wd.text, box,
          bold: x.bold,
          underline: x.underline,
          color: _inkColor(wd.box),
          confidence: markUncertain ? wd.confidence : null,
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
    var ink = 0.0, adv = 0.0;
    for (final wd in l.words) {
      ink += wd.box.width;
      adv += textAdvance(wd.text, bold: wd.bold) - 0.07; // side bearings
    }
    final byWidth = adv <= 0 ? 0.0 : ink / adv;
    // Height of capitals/ascenders ≈ 0.72 em; with descenders ≈ 0.93 em.
    final hs = <double>[];
    for (final wd in l.words) {
      final t = wd.text;
      final desc = RegExp(r'[gjpqy,;()\[\]{}@$]').hasMatch(t);
      final asc = RegExp(r'[A-Z0-9bdfhklt/\\|!?:]').hasMatch(t);
      if (!asc && !desc) {
        hs.add(wd.box.height / 0.53); // x-height
      } else {
        hs.add(wd.box.height / (desc ? (asc ? 0.93 : 0.73) : 0.73));
      }
    }
    final byHeight = median(hs);
    var size = byWidth > 0 ? byWidth : byHeight;
    if (byHeight > 0) size = clampD(size, byHeight * 0.7, byHeight * 1.35);
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
    final sizes = lines.map((l) => l.size).toList()..sort();
    final groups = <List<double>>[];
    for (final s in sizes) {
      if (groups.isNotEmpty && s <= groups.last.first * 1.09) {
        groups.last.add(s);
      } else {
        groups.add([s]);
      }
    }
    final centers = [for (final g in groups) halfPoint(median(g))];
    for (final l in lines) {
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
