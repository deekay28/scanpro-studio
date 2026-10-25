import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

/// Result of spine detection on a rectified two-page spread.
class SpineResult {
  /// Horizontal position of the spine as a fraction of the width.
  final double position;

  /// 0..1; low values mean the default centre split was used.
  final double confidence;
  const SpineResult(this.position, this.confidence);
}

/// Finds the book gutter: the darkest, narrow vertical band near the centre
/// (shadow of the binding). Searches 35%–65% of the width.
SpineResult detectSpine(Uint8List gray, int w, int h) {
  if (w < 20 || h < 20) return const SpineResult(0.5, 0);
  final profile = Float64List(w);
  final y0 = (h * 0.15).floor(), y1 = (h * 0.85).floor();
  for (var x = 0; x < w; x++) {
    var s = 0;
    for (var y = y0; y < y1; y++) {
      s += gray[y * w + x];
    }
    profile[x] = s / (y1 - y0);
  }
  final r = math.max(1, w ~/ 100);
  final smooth = Float64List(w);
  for (var x = 0; x < w; x++) {
    var s = 0.0;
    var n = 0;
    for (var k = math.max(0, x - r); k <= math.min(w - 1, x + r); k++) {
      s += profile[k];
      n++;
    }
    smooth[x] = s / n;
  }
  final a = (w * 0.35).floor(), b = (w * 0.65).ceil();
  var minX = w ~/ 2;
  var minV = double.infinity;
  for (var x = a; x < b; x++) {
    if (smooth[x] < minV) {
      minV = smooth[x];
      minX = x;
    }
  }
  final band = smooth.sublist(a, b).toList()..sort();
  final median = band[band.length ~/ 2];
  final contrast = median <= 0 ? 0.0 : (median - minV) / median;
  final confidence = (contrast / 0.12).clamp(0.0, 1.0).toDouble();
  if (confidence < 0.25) return SpineResult(0.5, confidence);
  return SpineResult(minX / (w - 1), confidence);
}

/// Least-squares quadratic fit y = c0 + c1 x + c2 x^2.
List<double>? fitQuadratic(List<double> xs, List<double> ys) {
  final n = xs.length;
  if (n < 3) return null;
  var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, t0 = 0.0, t1 = 0.0, t2 = 0.0;
  for (var i = 0; i < n; i++) {
    final x = xs[i], y = ys[i];
    final x2 = x * x;
    s0 += 1;
    s1 += x;
    s2 += x2;
    s3 += x2 * x;
    s4 += x2 * x2;
    t0 += y;
    t1 += x * y;
    t2 += x2 * y;
  }
  // Solve 3x3 via Cramer's rule.
  double det3(List<double> m) =>
      m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
  final m = [s0, s1, s2, s1, s2, s3, s2, s3, s4];
  final d = det3(m);
  if (d.abs() < 1e-9) return null;
  final m0 = [t0, s1, s2, t1, s2, s3, t2, s3, s4];
  final m1 = [s0, t0, s2, s1, t1, s3, s2, t2, s4];
  final m2 = [s0, s1, t0, s1, s2, t1, s2, s3, t2];
  return [det3(m0) / d, det3(m1) / d, det3(m2) / d];
}

double _evalQ(List<double> c, double x) => c[0] + c[1] * x + c[2] * x * x;

/// Approximate curved-page flattening based on the top and bottom page
/// edges visible against a darker background. Each column is resampled so
/// that both edges become straight. Returns null when the page edges cannot
/// be found reliably or the page is already flat (caller keeps the input).
Rgb? flattenCurvedPage(Rgb im) {
  final (sw, sh) = fitWithin(im.width, im.height, 400);
  final small = toGray(resizeRgb(im, sw, sh));
  final thr = otsuThreshold(small);
  final xs = <double>[], tops = <double>[], bottoms = <double>[];
  final topLimit = (sh * 0.35).floor(), botLimit = (sh * 0.65).floor();
  for (var x = 2; x < sw - 2; x += 3) {
    int? top, bottom;
    var run = 0;
    for (var y = 0; y < topLimit; y++) {
      run = small[y * sw + x] > thr ? run + 1 : 0;
      if (run >= 4) {
        top = y - 3;
        break;
      }
    }
    run = 0;
    for (var y = sh - 1; y > botLimit; y--) {
      run = small[y * sw + x] > thr ? run + 1 : 0;
      if (run >= 4) {
        bottom = y + 3;
        break;
      }
    }
    if (top != null && bottom != null && top > 0 && bottom < sh - 1) {
      xs.add(x.toDouble());
      tops.add(top.toDouble());
      bottoms.add(bottom.toDouble());
    }
  }
  final needed = (sw / 3) * 0.5;
  if (xs.length < needed) return null;
  final ct = fitQuadratic(xs, tops), cb = fitQuadratic(xs, bottoms);
  if (ct == null || cb == null) return null;
  // Curvature check: deviation of fitted curve from its chord.
  double dev(List<double> c) {
    final a = _evalQ(c, 0), b = _evalQ(c, sw - 1.0);
    var m = 0.0;
    for (var x = 0.0; x < sw; x += 4) {
      final chord = a + (b - a) * x / (sw - 1);
      m = math.max(m, (_evalQ(c, x) - chord).abs());
    }
    return m;
  }

  if (dev(ct) < sh * 0.005 && dev(cb) < sh * 0.005) return null;
  final scaleX = (sw - 1) / (im.width - 1), scaleY = im.height / sh;
  var meanH = 0.0;
  for (var i = 0; i < xs.length; i++) {
    meanH += bottoms[i] - tops[i];
  }
  meanH = meanH / xs.length * scaleY;
  final outH = math.max(16, meanH.round());
  final w = im.width;
  final out = Rgb.blank(w, outH);
  final s = im.data, o = out.data;
  for (var x = 0; x < w; x++) {
    final xsm = x * scaleX;
    final t = _evalQ(ct, xsm) * scaleY;
    final b = _evalQ(cb, xsm) * scaleY;
    final span = b - t;
    for (var y = 0; y < outH; y++) {
      var sy = t + (y + 0.5) / outH * span - 0.5;
      if (sy < 0) sy = 0;
      if (sy > im.height - 1) sy = (im.height - 1).toDouble();
      final y0 = sy.floor();
      final y1 = y0 + 1 < im.height ? y0 + 1 : y0;
      final f = sy - y0;
      final i0 = (y0 * w + x) * 3, i1 = (y1 * w + x) * 3, oi = (y * w + x) * 3;
      o[oi] = clamp255(s[i0] + (s[i1] - s[i0]) * f);
      o[oi + 1] = clamp255(s[i0 + 1] + (s[i1 + 1] - s[i0 + 1]) * f);
      o[oi + 2] = clamp255(s[i0 + 2] + (s[i1 + 2] - s[i0 + 2]) * f);
    }
  }
  return out;
}

/// Estimates skew (degrees) of text lines using projection-profile variance.
/// Searches ±[range] degrees. Works on a small gray image (~600 px).
double estimateSkew(Uint8List gray, int w, int h, {double range = 10, double step = 0.5}) {
  final thr = otsuThreshold(gray);
  final pts = <int>[];
  for (var y = 0; y < h; y += 1) {
    for (var x = 0; x < w; x += 1) {
      if (gray[y * w + x] < thr) pts.add(y * w + x);
    }
  }
  if (pts.length < 200 || pts.length > w * h * 0.5) return 0;
  final stride = math.max(1, pts.length ~/ 40000);
  var bestAngle = 0.0, bestScore = -1.0;
  final bins = Float64List(h * 2 + 2);
  for (var a = -range; a <= range + 1e-9; a += step) {
    bins.fillRange(0, bins.length, 0);
    final rad = a * math.pi / 180;
    final sa = math.sin(rad), ca = math.cos(rad);
    for (var k = 0; k < pts.length; k += stride) {
      final i = pts[k];
      final x = i % w, y = i ~/ w;
      final ry = (-sa * (x - w / 2) + ca * (y - h / 2) + h).round();
      if (ry >= 0 && ry < bins.length) bins[ry] += 1;
    }
    var score = 0.0;
    for (final v in bins) {
      score += v * v;
    }
    if (score > bestScore) {
      bestScore = score;
      bestAngle = a;
    }
  }
  // Lines are horizontal in the frame rotated by -bestAngle, so passing the
  // returned value to rotateFine() straightens the page.
  return bestAngle == 0 ? 0 : -bestAngle;
}
