import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/models.dart';
import 'book.dart';
import 'edge_detect.dart';
import 'filters.dart';
import 'image_ops.dart';
import 'perspective.dart';
import 'quality.dart';

/// Largest source image (in pixels) decoded at full resolution. Larger
/// images are downscaled on import (see ImportService) to avoid running
/// out of memory.
const int maxSourcePixels = 26000000;

/// Converts any decoded image to packed RGB, compositing alpha over white.
Rgb imageToRgb(img.Image im) {
  final w = im.width, h = im.height;
  if (im.hasAlpha) {
    final src = im.convert(format: img.Format.uint8, numChannels: 4);
    final b = src.getBytes(order: img.ChannelOrder.rgba);
    final out = Uint8List(w * h * 3);
    for (var i = 0, j = 0; j < out.length; i += 4, j += 3) {
      final a = b[i + 3];
      out[j] = (b[i] * a + 255 * (255 - a)) ~/ 255;
      out[j + 1] = (b[i + 1] * a + 255 * (255 - a)) ~/ 255;
      out[j + 2] = (b[i + 2] * a + 255 * (255 - a)) ~/ 255;
    }
    return Rgb(w, h, out);
  }
  final src = (im.numChannels == 3 && im.format == img.Format.uint8 && !im.hasPalette)
      ? im
      : im.convert(format: img.Format.uint8, numChannels: 3);
  final bytes = src.getBytes(order: img.ChannelOrder.rgb);
  return Rgb(w, h, Uint8List.fromList(bytes));
}

img.Image rgbToImage(Rgb rgb) {
  final data = rgb.data.offsetInBytes == 0 && rgb.data.lengthInBytes == rgb.data.buffer.lengthInBytes
      ? rgb.data
      : Uint8List.fromList(rgb.data);
  return img.Image.fromBytes(
    width: rgb.width,
    height: rgb.height,
    bytes: data.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}

/// Decodes a file, applies EXIF orientation and returns RGB.
Rgb loadRgb(String path) {
  final file = File(path);
  if (!file.existsSync()) throw const FileSystemException('Image file is missing');
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) throw const FormatException('The image file is empty.');
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) throw const FormatException('The image is corrupted or in an unsupported format.');
  if (decoded.width * decoded.height > maxSourcePixels * 1.1) {
    throw const FormatException('The image is too large to process.');
  }
  decoded = img.bakeOrientation(decoded);
  return imageToRgb(decoded);
}

void writeAtomic(String path, List<int> bytes) {
  final tmp = File('$path.part');
  tmp.parent.createSync(recursive: true);
  tmp.writeAsBytesSync(bytes, flush: true);
  final target = File(path);
  if (target.existsSync()) target.deleteSync();
  tmp.renameSync(path);
}

Uint8List encodeJpeg(Rgb rgb, int quality) => img.encodeJpg(rgbToImage(rgb), quality: quality);

// ---------------------------------------------------------------------------
// Page processing
// ---------------------------------------------------------------------------

class ProcessInput {
  final String originalPath;
  final String outPath;
  final String thumbPath;
  final Map<String, dynamic> edit;
  final int maxDim;
  final int quality;
  const ProcessInput({
    required this.originalPath,
    required this.outPath,
    required this.thumbPath,
    required this.edit,
    this.maxDim = 2800,
    this.quality = 90,
  });
}

class ProcessOutput {
  final int width;
  final int height;
  final bool flattenApplied;
  const ProcessOutput(this.width, this.height, this.flattenApplied);
}

/// Produces the processed page and its thumbnail from the untouched
/// original. Runs in a background isolate.
Future<ProcessOutput> processPage(ProcessInput input) => Isolate.run(() => _processPage(input));

ProcessOutput _processPage(ProcessInput input) {
  final edit = PageEdit.fromJson(input.edit);
  var src = loadRgb(input.originalPath);
  final (rgb, flat) = renderEdit(src, edit, input.maxDim);
  writeAtomic(input.outPath, encodeJpeg(rgb, input.quality));
  final (tw, th) = fitWithin(rgb.width, rgb.height, 360);
  writeAtomic(input.thumbPath, encodeJpeg(resizeRgb(rgb, tw, th), 80));
  return ProcessOutput(rgb.width, rgb.height, flat);
}

/// Applies geometry + filters. Returns the image and whether flattening
/// was actually applied.
(Rgb, bool) renderEdit(Rgb src, PageEdit edit, int maxDim) {
  Rgb out;
  final corners = edit.corners;
  if (corners != null && corners.length == 8) {
    var q = [for (var i = 0; i < 4; i++) Pt(corners[i * 2] * src.width, corners[i * 2 + 1] * src.height)];
    final (ow, oh) = quadOutputSize(q);
    final (tw, th) = fitWithin(ow, oh, maxDim);
    final scale = tw / ow;
    if (scale < 0.6) {
      final f = math.min(1.0, scale * 1.3);
      final nw = math.max(1, (src.width * f).round()), nh = math.max(1, (src.height * f).round());
      final fx = nw / src.width, fy = nh / src.height;
      src = resizeRgb(src, nw, nh);
      q = [for (final p in q) Pt(p.x * fx, p.y * fy)];
    }
    out = warpPerspective(src, q, tw, th);
  } else {
    final (tw, th) = fitWithin(src.width, src.height, maxDim);
    out = resizeRgb(src, tw, th);
  }
  out = rotate90s(out, edit.rotation);
  var flat = false;
  if (edit.flatten) {
    final f = flattenCurvedPage(out);
    if (f != null) {
      out = f;
      flat = true;
    }
  }
  if (edit.fineAngle.abs() > 0.01) out = rotateFine(out, edit.fineAngle);
  out = applyFilters(out, edit);
  return (out, flat);
}

// ---------------------------------------------------------------------------
// Preview rendering (editor)
// ---------------------------------------------------------------------------

/// Creates a downscaled, orientation-corrected copy of [originalPath] for
/// fast interactive previews. Returns its (width, height).
Future<(int, int)> makePreviewSource(String originalPath, String outPath, {int maxDim = 1400}) =>
    Isolate.run(() {
      final src = loadRgb(originalPath);
      final (w, h) = fitWithin(src.width, src.height, maxDim);
      final small = resizeRgb(src, w, h);
      writeAtomic(outPath, encodeJpeg(small, 92));
      return (w, h);
    });

/// Renders [edit] on the preview source; returns JPEG bytes.
Future<Uint8List> renderPreview(String previewSourcePath, Map<String, dynamic> editJson, {int maxDim = 1400}) =>
    Isolate.run(() {
      final src = loadRgb(previewSourcePath);
      final (rgb, _) = renderEdit(src, PageEdit.fromJson(editJson), maxDim);
      return encodeJpeg(rgb, 88);
    });

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

class ImageAnalysis {
  final int width;
  final int height;
  final List<String> flags;
  final String hash;
  final List<double>? corners; // normalised, TL TR BR BL
  final double detectionScore;
  final String shapeHint;
  const ImageAnalysis({
    required this.width,
    required this.height,
    required this.flags,
    required this.hash,
    required this.corners,
    required this.detectionScore,
    required this.shapeHint,
  });
}

Future<ImageAnalysis> analyzeImage(String path, {bool documentExpected = true}) =>
    Isolate.run(() => analyzeImageSync(path, documentExpected: documentExpected));

ImageAnalysis analyzeImageSync(String path, {bool documentExpected = true}) {
  final src = loadRgb(path);
  final (w, h) = fitWithin(src.width, src.height, 512);
  final small = resizeRgb(src, w, h);
  final report = analyzeQuality(small, sourceWidth: src.width, sourceHeight: src.height);
  final quad = report.quad;
  String hint = 'Custom';
  if (quad != null) {
    final px = [for (final p in quad.quad) Pt(p.x * src.width, p.y * src.height)];
    final (ow, oh) = quadOutputSize(px);
    hint = _describe(oh / ow);
  }
  return ImageAnalysis(
    width: src.width,
    height: src.height,
    flags: report.flags(documentExpected: documentExpected),
    hash: report.dHash,
    corners: quad == null ? null : quadToList(quad.quad),
    detectionScore: quad?.score ?? 0,
    shapeHint: hint,
  );
}

String _describe(double aspect) {
  final a = aspect < 1 ? 1 / aspect : aspect;
  if ((a - 1.414).abs() < 0.05) return 'A-series (A4)';
  if ((a - 1.294).abs() < 0.04) return 'Letter';
  if ((a - 1.647).abs() < 0.05) return 'Legal';
  if ((a - 1.586).abs() < 0.06) return 'ID card';
  if (a > 2.0) return 'Receipt';
  return 'Custom';
}

/// Detects corners on a camera frame's luminance (used by the live camera
/// overlay). [y] is a tightly packed gray buffer.
QuadDetection? detectOnGray(Uint8List y, int w, int h) => detectDocumentQuad(y, w, h);

// ---------------------------------------------------------------------------
// Book spreads
// ---------------------------------------------------------------------------

class SpreadAnalysis {
  final List<double> spreadCorners; // normalised quad of the whole spread
  final double spine; // fraction across the rectified spread
  final double spineConfidence;
  const SpreadAnalysis(this.spreadCorners, this.spine, this.spineConfidence);
}

Future<SpreadAnalysis> analyzeSpread(String path) => Isolate.run(() {
      final src = loadRgb(path);
      final (w, h) = fitWithin(src.width, src.height, 700);
      final small = resizeRgb(src, w, h);
      final (dw, dh) = fitWithin(w, h, 256);
      final tiny = toGray(resizeRgb(small, dw, dh));
      final quad = detectDocumentQuad(tiny, dw, dh)?.quad ?? defaultQuad();
      final px = [for (final p in quad) Pt(p.x * w, p.y * h)];
      final (ow, oh) = quadOutputSize(px);
      final (tw, th) = fitWithin(ow, oh, 700);
      final rect = warpPerspective(small, px, tw, th);
      final spine = detectSpine(toGray(rect), tw, th);
      return SpreadAnalysis(quadToList(quad), spine.position, spine.confidence);
    });

/// Splits a spread quad into left/right page quads with [overlap] (fraction
/// of spread width) on each side of the spine so text near the binding is
/// never cut off.
(List<double>, List<double>) splitSpread(List<double> spreadCorners, double spine, {double overlap = 0.012}) {
  final q = listToQuad(spreadCorners);
  final left = subQuadHorizontal(q, 0, math.min(1.0, spine + overlap));
  final right = subQuadHorizontal(q, math.max(0.0, spine - overlap), 1);
  return (quadToList(left), quadToList(right));
}

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

Future<double> estimateSkewForFile(String path) => Isolate.run(() {
      final src = loadRgb(path);
      final (w, h) = fitWithin(src.width, src.height, 700);
      final g = toGray(resizeRgb(src, w, h));
      return estimateSkew(g, w, h);
    });

/// Prepares a page image for PDF embedding: optional annotation overlay
/// composited on top, downscaled to [maxDim], re-encoded at [quality].
Future<(Uint8List, int, int)> preparePdfImage(String path, {String? overlayPath, int maxDim = 2400, int quality = 85, bool gray = false}) =>
    Isolate.run(() {
      var rgb = loadRgb(path);
      final (w, h) = fitWithin(rgb.width, rgb.height, maxDim);
      rgb = resizeRgb(rgb, w, h);
      if (overlayPath != null && File(overlayPath).existsSync()) {
        final ov = img.decodePng(File(overlayPath).readAsBytesSync());
        if (ov != null) {
          final resized = img.copyResize(ov, width: w, height: h, interpolation: img.Interpolation.linear)
              .convert(format: img.Format.uint8, numChannels: 4);
          final b = resized.getBytes(order: img.ChannelOrder.rgba);
          final d = rgb.data;
          for (var i = 0, j = 0; j < d.length; i += 4, j += 3) {
            final a = b[i + 3];
            if (a == 0) continue;
            d[j] = (b[i] * a + d[j] * (255 - a)) ~/ 255;
            d[j + 1] = (b[i + 1] * a + d[j + 1] * (255 - a)) ~/ 255;
            d[j + 2] = (b[i + 2] * a + d[j + 2] * (255 - a)) ~/ 255;
          }
        }
      }
      if (gray) rgb = grayToRgb(toGray(rgb), rgb.width, rgb.height);
      return (encodeJpeg(rgb, quality), rgb.width, rgb.height);
    });

/// Writes an RGBA/any image file as a normalised JPEG "original".
Future<(int, int)> normalizeToJpeg(String srcPath, String outPath, {int maxPixels = maxSourcePixels}) => Isolate.run(() {
      final bytes = File(srcPath).readAsBytesSync();
      var decoded = img.decodeImage(bytes);
      if (decoded == null) throw const FormatException('Unsupported image format.');
      decoded = img.bakeOrientation(decoded);
      var rgb = imageToRgb(decoded);
      if (rgb.pixels > maxPixels) {
        final s = math.sqrt(maxPixels / rgb.pixels);
        rgb = resizeRgb(rgb, (rgb.width * s).floor(), (rgb.height * s).floor());
      }
      writeAtomic(outPath, encodeJpeg(rgb, 95));
      return (rgb.width, rgb.height);
    });

/// Converts raw RGBA pixels (e.g. from Flutter's decoder) to a JPEG file.
Future<void> rgbaToJpegFile(Uint8List rgba, int w, int h, String outPath, {int quality = 95}) => Isolate.run(() {
      final out = Uint8List(w * h * 3);
      for (var i = 0, j = 0; j < out.length; i += 4, j += 3) {
        final a = rgba[i + 3];
        out[j] = (rgba[i] * a + 255 * (255 - a)) ~/ 255;
        out[j + 1] = (rgba[i + 1] * a + 255 * (255 - a)) ~/ 255;
        out[j + 2] = (rgba[i + 2] * a + 255 * (255 - a)) ~/ 255;
      }
      writeAtomic(outPath, encodeJpeg(Rgb(w, h, out), quality));
    });
