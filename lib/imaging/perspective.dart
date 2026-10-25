import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

/// A 2D point in pixel or normalised coordinates.
class Pt {
  final double x;
  final double y;
  const Pt(this.x, this.y);
  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt scale(double sx, [double? sy]) => Pt(x * sx, y * (sy ?? sx));
  double dist(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
  @override
  String toString() => 'Pt(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// 3x3 projective transform (h8 = 1).
class Homography {
  final List<double> h; // 9 values row-major
  const Homography(this.h);

  Pt apply(Pt p) {
    final w = h[6] * p.x + h[7] * p.y + h[8];
    return Pt((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w);
  }

  /// Solves the homography mapping [src] points to [dst] points (4 each).
  static Homography fromPoints(List<Pt> src, List<Pt> dst) {
    final a = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final s = src[i], d = dst[i];
      a[i * 2] = [s.x, s.y, 1, 0, 0, 0, -d.x * s.x, -d.x * s.y, d.x];
      a[i * 2 + 1] = [0, 0, 0, s.x, s.y, 1, -d.y * s.x, -d.y * s.y, d.y];
    }
    // Gaussian elimination with partial pivoting.
    for (var col = 0; col < 8; col++) {
      var pivot = col;
      for (var r = col + 1; r < 8; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) {
        throw ArgumentError('Degenerate quadrilateral');
      }
      final tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;
      final pv = a[col][col];
      for (var c = col; c < 9; c++) {
        a[col][c] /= pv;
      }
      for (var r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = a[r][col];
        if (f == 0) continue;
        for (var c = col; c < 9; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return Homography([a[0][8], a[1][8], a[2][8], a[3][8], a[4][8], a[5][8], a[6][8], a[7][8], 1]);
  }
}

/// Orders 4 points as TL, TR, BR, BL.
List<Pt> orderQuad(List<Pt> pts) {
  if (pts.length != 4) throw ArgumentError('Need 4 points');
  final cx = pts.fold<double>(0, (s, p) => s + p.x) / 4;
  final cy = pts.fold<double>(0, (s, p) => s + p.y) / 4;
  final sorted = [...pts]..sort((a, b) => math.atan2(a.y - cy, a.x - cx).compareTo(math.atan2(b.y - cy, b.x - cx)));
  // atan2 ascending in screen coords (y down) goes TL(-135°) -> TR(-45°) -> BR(45°) -> BL(135°).
  var start = 0;
  var best = double.infinity;
  for (var i = 0; i < 4; i++) {
    final s = sorted[i].x + sorted[i].y;
    if (s < best) {
      best = s;
      start = i;
    }
  }
  return List.generate(4, (i) => sorted[(start + i) % 4]);
}

double polygonArea(List<Pt> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    final j = (i + 1) % p.length;
    a += p[i].x * p[j].y - p[j].x * p[i].y;
  }
  return a.abs() / 2;
}

bool isConvexQuad(List<Pt> q) {
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    final s = cross > 0 ? 1 : (cross < 0 ? -1 : 0);
    if (s == 0) return false;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// Output size (w,h) for a perspective-corrected quad in pixel coordinates.
(int, int) quadOutputSize(List<Pt> q) {
  final w = math.max(q[0].dist(q[1]), q[3].dist(q[2]));
  final h = math.max(q[0].dist(q[3]), q[1].dist(q[2]));
  return (math.max(1, w.round()), math.max(1, h.round()));
}

/// Perspective-warps quad [q] (TL,TR,BR,BL in source pixels) into a
/// rectangle of size [outW] x [outH] using bilinear sampling.
Rgb warpPerspective(Rgb src, List<Pt> q, int outW, int outH) {
  final dstRect = [Pt(0, 0), Pt(outW.toDouble(), 0), Pt(outW.toDouble(), outH.toDouble()), Pt(0, outH.toDouble())];
  final hm = Homography.fromPoints(dstRect, q).h; // output -> source
  final sw = src.width, sh = src.height, s = src.data;
  final o = Uint8List(outW * outH * 3);
  for (var y = 0; y < outH; y++) {
    final py = y + 0.5;
    for (var x = 0; x < outW; x++) {
      final px = x + 0.5;
      final w = hm[6] * px + hm[7] * py + hm[8];
      var sx = (hm[0] * px + hm[1] * py + hm[2]) / w - 0.5;
      var sy = (hm[3] * px + hm[4] * py + hm[5]) / w - 0.5;
      final oi = (y * outW + x) * 3;
      if (sx < -1 || sy < -1 || sx > sw || sy > sh) {
        o[oi] = 255;
        o[oi + 1] = 255;
        o[oi + 2] = 255;
        continue;
      }
      if (sx < 0) sx = 0;
      if (sy < 0) sy = 0;
      if (sx > sw - 1) sx = (sw - 1).toDouble();
      if (sy > sh - 1) sy = (sh - 1).toDouble();
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 + 1 < sw ? x0 + 1 : x0, y1 = y0 + 1 < sh ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3, i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
      for (var c = 0; c < 3; c++) {
        final top = s[i00 + c] + (s[i10 + c] - s[i00 + c]) * fx;
        final bot = s[i01 + c] + (s[i11 + c] - s[i01 + c]) * fx;
        o[oi + c] = clamp255(top + (bot - top) * fy);
      }
    }
  }
  return Rgb(outW, outH, o);
}

/// Sub-quad of [q] between horizontal fractions [x0]..[x1] of the
/// rectified page (used to split book spreads exactly in perspective).
List<Pt> subQuadHorizontal(List<Pt> q, double x0, double x1) {
  final unit = [const Pt(0, 0), const Pt(1, 0), const Pt(1, 1), const Pt(0, 1)];
  final h = Homography.fromPoints(unit, q);
  return [h.apply(Pt(x0, 0)), h.apply(Pt(x1, 0)), h.apply(Pt(x1, 1)), h.apply(Pt(x0, 1))];
}

List<double> quadToList(List<Pt> q) => [for (final p in q) ...[p.x, p.y]];
List<Pt> listToQuad(List<double> l) => [for (var i = 0; i < 4; i++) Pt(l[i * 2], l[i * 2 + 1])];
