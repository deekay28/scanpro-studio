import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';
import 'perspective.dart';

/// Result of automatic document boundary detection.
class QuadDetection {
  /// TL, TR, BR, BL in normalised (0..1) coordinates.
  final List<Pt> quad;

  /// 0..1 confidence (rectangularity × coverage heuristics).
  final double score;
  final bool touchesBorder;
  const QuadDetection(this.quad, this.score, this.touchesBorder);
}

/// Detects the dominant document quadrilateral in a small grayscale image.
///
/// Two strategies are tried and the best-scoring candidate wins:
///  1. Brightness segmentation (paper brighter than background, Otsu).
///  2. Edge-enclosed region (Sobel edges, flood-fill background from borders).
/// The component's convex hull is reduced to the maximum-area inscribed
/// quadrilateral. Returns null when nothing plausible is found, in which
/// case callers fall back to the full frame + manual corner adjustment.
QuadDetection? detectDocumentQuad(Uint8List gray, int w, int h) {
  if (w < 16 || h < 16) return null;
  final blurred = boxBlurU8(gray, w, h, 1);
  final candidates = <QuadDetection>[];

  // Strategy 1: brightness.
  final t = otsuThreshold(blurred);
  final bright = Uint8List(w * h);
  for (var i = 0; i < bright.length; i++) {
    bright[i] = blurred[i] > t ? 1 : 0;
  }
  final c1 = _quadFromMask(_largestComponent(bright, w, h), w, h);
  if (c1 != null) candidates.add(c1);

  // Strategy 2: edges.
  final edges = _sobelEdges(blurred, w, h);
  final dil = _dilate(edges, w, h);
  final inside = _interiorFromEdges(dil, w, h);
  final c2 = _quadFromMask(_largestComponent(inside, w, h), w, h);
  if (c2 != null) candidates.add(c2);

  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.score.compareTo(a.score));
  final best = candidates.first;
  return best.score >= 0.35 ? best : null;
}

Uint8List _sobelEdges(Uint8List g, int w, int h) {
  final mag = Float32List(w * h);
  var sum = 0.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final gx = -g[i - w - 1] - 2 * g[i - 1] - g[i + w - 1] + g[i - w + 1] + 2 * g[i + 1] + g[i + w + 1];
      final gy = -g[i - w - 1] - 2 * g[i - w] - g[i - w + 1] + g[i + w - 1] + 2 * g[i + w] + g[i + w + 1];
      final m = math.sqrt((gx * gx + gy * gy).toDouble());
      mag[i] = m;
      sum += m;
    }
  }
  final mean = sum / (w * h);
  var sq = 0.0;
  for (final m in mag) {
    sq += (m - mean) * (m - mean);
  }
  final std = math.sqrt(sq / (w * h));
  final thr = mean + 1.0 * std;
  final out = Uint8List(w * h);
  for (var i = 0; i < out.length; i++) {
    out[i] = mag[i] > thr ? 1 : 0;
  }
  return out;
}

Uint8List _dilate(Uint8List m, int w, int h) {
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (m[y * w + x] == 0) continue;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          out[yy * w + xx] = 1;
        }
      }
    }
  }
  return out;
}

/// Pixels not reachable from the image border without crossing an edge.
Uint8List _interiorFromEdges(Uint8List edges, int w, int h) {
  final outside = Uint8List(w * h);
  final stack = <int>[];
  void push(int i) {
    if (edges[i] == 0 && outside[i] == 0) {
      outside[i] = 1;
      stack.add(i);
    }
  }

  for (var x = 0; x < w; x++) {
    push(x);
    push((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    push(y * w);
    push(y * w + w - 1);
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w, y = i ~/ w;
    if (x > 0) push(i - 1);
    if (x < w - 1) push(i + 1);
    if (y > 0) push(i - w);
    if (y < h - 1) push(i + w);
  }
  final inside = Uint8List(w * h);
  for (var i = 0; i < inside.length; i++) {
    inside[i] = outside[i] == 0 ? 1 : 0;
  }
  return inside;
}

/// Keeps only the largest 4-connected component of a binary mask.
Uint8List _largestComponent(Uint8List mask, int w, int h) {
  final labels = Int32List(w * h);
  var bestLabel = 0, bestSize = 0, label = 0;
  final stack = <int>[];
  for (var s = 0; s < mask.length; s++) {
    if (mask[s] == 0 || labels[s] != 0) continue;
    label++;
    var size = 0;
    labels[s] = label;
    stack.add(s);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      size++;
      final x = i % w, y = i ~/ w;
      if (x > 0 && mask[i - 1] == 1 && labels[i - 1] == 0) {
        labels[i - 1] = label;
        stack.add(i - 1);
      }
      if (x < w - 1 && mask[i + 1] == 1 && labels[i + 1] == 0) {
        labels[i + 1] = label;
        stack.add(i + 1);
      }
      if (y > 0 && mask[i - w] == 1 && labels[i - w] == 0) {
        labels[i - w] = label;
        stack.add(i - w);
      }
      if (y < h - 1 && mask[i + w] == 1 && labels[i + w] == 0) {
        labels[i + w] = label;
        stack.add(i + w);
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = label;
    }
  }
  final out = Uint8List(w * h);
  if (bestLabel == 0) return out;
  for (var i = 0; i < out.length; i++) {
    if (labels[i] == bestLabel) out[i] = 1;
  }
  return out;
}

QuadDetection? _quadFromMask(Uint8List comp, int w, int h) {
  var area = 0;
  final pts = <Pt>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (comp[i] == 0) continue;
      area++;
      final boundary = x == 0 || y == 0 || x == w - 1 || y == h - 1 || comp[i - 1] == 0 || comp[i + 1] == 0 || comp[i - w] == 0 || comp[i + w] == 0;
      if (boundary) pts.add(Pt(x.toDouble(), y.toDouble()));
    }
  }
  final total = w * h;
  if (area < total * 0.12 || area > total * 0.995 || pts.length < 8) return null;
  var hull = convexHull(pts);
  if (hull.length < 4) return null;
  if (hull.length > 64) {
    final step = hull.length / 64;
    hull = [for (var i = 0; i < 64; i++) hull[(i * step).floor()]];
  }
  final quad = maxAreaQuad(hull);
  if (quad == null) return null;
  final ordered = orderQuad(quad);
  if (!isConvexQuad(ordered)) return null;
  final qa = polygonArea(ordered);
  if (qa < total * 0.12) return null;
  final rectangularity = math.min(1.0, area / qa);
  final coverage = qa / total;
  // Penalise quads with extreme angles.
  var angleScore = 1.0;
  for (var i = 0; i < 4; i++) {
    final a = ordered[(i + 3) % 4], b = ordered[i], c = ordered[(i + 1) % 4];
    final v1 = a - b, v2 = c - b;
    final cos = (v1.x * v2.x + v1.y * v2.y) / (math.sqrt(v1.x * v1.x + v1.y * v1.y) * math.sqrt(v2.x * v2.x + v2.y * v2.y) + 1e-9);
    final ang = math.acos(cos.clamp(-1.0, 1.0).toDouble()) * 180 / math.pi;
    if (ang < 45 || ang > 135) angleScore *= 0.5;
  }
  final margin = 1.5;
  final touches = ordered.any((p) => p.x <= margin || p.y <= margin || p.x >= w - 1 - margin || p.y >= h - 1 - margin);
  final coverageScore = coverage > 0.97 ? 0.4 : 1.0; // whole frame is not informative
  final score = rectangularity * angleScore * coverageScore * (touches ? 0.85 : 1.0);
  final norm = [for (final p in ordered) Pt(p.x / (w - 1), p.y / (h - 1))];
  return QuadDetection(norm, score, touches);
}

/// Andrew's monotone chain convex hull.
List<Pt> convexHull(List<Pt> points) {
  final p = [...points]..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  if (p.length < 3) return p;
  double cross(Pt o, Pt a, Pt b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <Pt>[];
  for (final pt in p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, pt) <= 0) {
      lower.removeLast();
    }
    lower.add(pt);
  }
  final upper = <Pt>[];
  for (final pt in p.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, pt) <= 0) {
      upper.removeLast();
    }
    upper.add(pt);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

double _tri(Pt a, Pt b, Pt c) => ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;

/// Maximum-area quadrilateral with vertices on the convex hull.
List<Pt>? maxAreaQuad(List<Pt> hull) {
  final n = hull.length;
  if (n < 4) return null;
  var best = -1.0;
  List<Pt>? bestQ;
  for (var i = 0; i < n; i++) {
    for (var j = i + 2; j < n; j++) {
      if (i == 0 && j == n - 1) continue;
      // Best vertex on each side of diagonal i-j.
      var a1 = -1.0;
      int? k1;
      for (var k = i + 1; k < j; k++) {
        final a = _tri(hull[i], hull[j], hull[k]);
        if (a > a1) {
          a1 = a;
          k1 = k;
        }
      }
      var a2 = -1.0;
      int? k2;
      for (var k = j + 1; k < n + i; k++) {
        final kk = k % n;
        final a = _tri(hull[i], hull[j], hull[kk]);
        if (a > a2) {
          a2 = a;
          k2 = kk;
        }
      }
      if (k1 == null || k2 == null) continue;
      final total = a1 + a2;
      if (total > best) {
        best = total;
        bestQ = [hull[i], hull[k1], hull[j], hull[k2]];
      }
    }
  }
  return bestQ;
}

/// Default crop used when detection fails: full frame with a tiny inset.
List<Pt> defaultQuad({double inset = 0.0}) =>
    [Pt(inset, inset), Pt(1 - inset, inset), Pt(1 - inset, 1 - inset), Pt(inset, 1 - inset)];
