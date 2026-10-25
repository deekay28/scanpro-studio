import 'dart:math' as math;
import 'dart:typed_data';

import '../core/models.dart';
import 'edge_detect.dart';
import 'image_ops.dart';

/// Image quality metrics computed on a small grayscale copy (~512 px).
class QualityReport {
  final double sharpness; // variance of Laplacian
  final double meanLuma;
  final double clippedHighlights; // fraction of pixels > 250
  final double clippedShadows; // fraction of pixels < 8
  final QuadDetection? quad;
  final String dHash; // 64-bit hex
  final int sourceWidth;
  final int sourceHeight;

  const QualityReport({
    required this.sharpness,
    required this.meanLuma,
    required this.clippedHighlights,
    required this.clippedShadows,
    required this.quad,
    required this.dHash,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  List<String> flags({bool documentExpected = true}) {
    final f = <String>[];
    if (sharpness < blurThreshold) f.add(QualityFlag.blurry);
    if (meanLuma < 55 || clippedShadows > 0.45) f.add(QualityFlag.dark);
    if (clippedHighlights > 0.25) f.add(QualityFlag.overexposed);
    if (documentExpected && quad != null && quad!.touchesBorder) f.add(QualityFlag.incomplete);
    if (math.max(sourceWidth, sourceHeight) < 1000) f.add(QualityFlag.lowRes);
    return f;
  }

  /// Empirical threshold for a 512 px gray image (box-blurred once).
  static const double blurThreshold = 35;
}

double laplacianVariance(Uint8List g, int w, int h) {
  if (w < 3 || h < 3) return 0;
  var sum = 0.0, sq = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final l = (g[i - 1] + g[i + 1] + g[i - w] + g[i + w] - 4 * g[i]).toDouble();
      sum += l;
      sq += l * l;
      n++;
    }
  }
  final mean = sum / n;
  return sq / n - mean * mean;
}

/// Difference hash on a 9x8 thumbnail; robust to scale and small edits.
String dHash(Uint8List g, int w, int h) {
  final small = Uint8List(9 * 8);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 9; x++) {
      final x0 = x * w ~/ 9, x1 = math.max(x0 + 1, (x + 1) * w ~/ 9);
      final y0 = y * h ~/ 8, y1 = math.max(y0 + 1, (y + 1) * h ~/ 8);
      var s = 0, n = 0;
      for (var yy = y0; yy < y1 && yy < h; yy++) {
        for (var xx = x0; xx < x1 && xx < w; xx++) {
          s += g[yy * w + xx];
          n++;
        }
      }
      small[y * 9 + x] = n == 0 ? 0 : s ~/ n;
    }
  }
  final sb = StringBuffer();
  for (var y = 0; y < 8; y++) {
    var byte = 0;
    for (var x = 0; x < 8; x++) {
      byte = (byte << 1) | (small[y * 9 + x] > small[y * 9 + x + 1] ? 1 : 0);
    }
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

int hammingHex(String a, String b) {
  if (a.length != b.length) return 64;
  var d = 0;
  for (var i = 0; i < a.length; i += 2) {
    var x = int.parse(a.substring(i, i + 2), radix: 16) ^ int.parse(b.substring(i, i + 2), radix: 16);
    while (x != 0) {
      d += x & 1;
      x >>= 1;
    }
  }
  return d;
}

bool isDuplicateHash(String a, String b, {int maxDistance = 5}) => hammingHex(a, b) <= maxDistance;

/// Full analysis of a (downscaled) RGB image.
QualityReport analyzeQuality(Rgb small, {required int sourceWidth, required int sourceHeight}) {
  final g = toGray(small);
  final w = small.width, h = small.height;
  final blurred = boxBlurU8(g, w, h, 1);
  final sharp = laplacianVariance(blurred, w, h);
  var sum = 0, hi = 0, lo = 0;
  for (final v in g) {
    sum += v;
    if (v > 250) hi++;
    if (v < 8) lo++;
  }
  // Detect on an even smaller copy for speed.
  final (dw, dh) = fitWithin(w, h, 256);
  final tiny = dw == w ? g : toGray(resizeRgb(small, dw, dh));
  final quad = detectDocumentQuad(tiny, dw, dh);
  return QualityReport(
    sharpness: sharp,
    meanLuma: sum / g.length,
    clippedHighlights: hi / g.length,
    clippedShadows: lo / g.length,
    quad: quad,
    dHash: dHash(g, w, h),
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}
