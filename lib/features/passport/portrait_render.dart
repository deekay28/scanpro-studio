import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../imaging/image_ops.dart';
import '../../imaging/processor.dart';

/// Portrait framing in source-image pixels: the crop rectangle is centred
/// at (cx, cy), has height [cropH] (width = cropH / aspect) and is rotated
/// by [angle] degrees (straightening).
class PortraitCrop {
  final double cx, cy, cropH, angle;
  const PortraitCrop(this.cx, this.cy, this.cropH, this.angle);
  PortraitCrop copyWith({double? cx, double? cy, double? cropH, double? angle}) =>
      PortraitCrop(cx ?? this.cx, cy ?? this.cy, cropH ?? this.cropH, angle ?? this.angle);
  Map<String, double> toJson() => {'cx': cx, 'cy': cy, 'h': cropH, 'a': angle};
}

/// Suggests a crop from a detected face box so the head height and top
/// margin match the preset. ML Kit's face box spans roughly eyebrows to
/// chin, so the crown is estimated above it.
PortraitCrop suggestCrop({
  required double faceLeft,
  required double faceTop,
  required double faceWidth,
  required double faceHeight,
  required double aspect, // photo height / width
  required double headFraction,
  required double topMargin,
  double rollDegrees = 0,
}) {
  final chin = faceTop + faceHeight * 1.02;
  final crown = faceTop - faceHeight * 0.42;
  final head = chin - crown;
  final cropH = head / headFraction;
  final top = crown - topMargin * cropH;
  return PortraitCrop(faceLeft + faceWidth / 2, top + cropH / 2, cropH, -rollDegrees);
}

/// Renders the crop to [outW]x[outH] (bilinear, white outside the source).
Rgb renderCrop(Rgb src, PortraitCrop c, int outW, int outH) {
  final out = Rgb.blank(outW, outH);
  final scale = c.cropH / outH; // source px per output px
  final a = c.angle * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  final s = src.data, o = out.data;
  final sw = src.width, sh = src.height;
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      final dx = (x + 0.5 - outW / 2) * scale, dy = (y + 0.5 - outH / 2) * scale;
      // Rotating the frame by +angle means sampling the source rotated by -angle.
      final sx = c.cx + ca * dx - sa * dy - 0.5;
      final sy = c.cy + sa * dx + ca * dy - 0.5;
      if (sx < 0 || sy < 0 || sx > sw - 1 || sy > sh - 1) continue;
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 + 1 < sw ? x0 + 1 : x0, y1 = y0 + 1 < sh ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      final oi = (y * outW + x) * 3;
      for (var ch = 0; ch < 3; ch++) {
        final t = s[(y0 * sw + x0) * 3 + ch] * (1 - fx) + s[(y0 * sw + x1) * 3 + ch] * fx;
        final b = s[(y1 * sw + x0) * 3 + ch] * (1 - fx) + s[(y1 * sw + x1) * 3 + ch] * fx;
        o[oi + ch] = clamp255(t * (1 - fy) + b * fy);
      }
    }
  }
  return out;
}

/// A refinement brush stroke on the mask (normalised coordinates).
class MaskStroke {
  final List<double> points; // x0,y0,x1,y1,... normalised
  final double radius; // fraction of image width
  final bool keep; // true = subject, false = background
  const MaskStroke(this.points, this.radius, this.keep);
  Map<String, dynamic> toJson() => {'p': points, 'r': radius, 'k': keep};
  factory MaskStroke.fromJson(Map<String, dynamic> j) =>
      MaskStroke((j['p'] as List).map((e) => (e as num).toDouble()).toList(), (j['r'] as num).toDouble(), j['k'] as bool);
}

void applyStrokes(Uint8List mask, int w, int h, List<MaskStroke> strokes) {
  for (final st in strokes) {
    final r = math.max(1.0, st.radius * w);
    final v = st.keep ? 255 : 0;
    final pts = st.points;
    for (var i = 0; i + 1 < pts.length; i += 2) {
      // Interpolate between consecutive points for continuous strokes.
      final x1 = pts[i] * w, y1 = pts[i + 1] * h;
      final hasNext = i + 3 < pts.length;
      final x2 = hasNext ? pts[i + 2] * w : x1, y2 = hasNext ? pts[i + 3] * h : y1;
      final steps = math.max(1, (math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)) / (r / 2)).ceil());
      for (var k = 0; k <= steps; k++) {
        final cx = x1 + (x2 - x1) * k / steps, cy = y1 + (y2 - y1) * k / steps;
        final xa = math.max(0, (cx - r).floor()), xb = math.min(w - 1, (cx + r).ceil());
        final ya = math.max(0, (cy - r).floor()), yb = math.min(h - 1, (cy + r).ceil());
        for (var y = ya; y <= yb; y++) {
          for (var x = xa; x <= xb; x++) {
            final d = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            if (d <= r) mask[y * w + x] = v;
          }
        }
      }
    }
  }
}

/// Converts raw segmentation confidences to a clean 8-bit alpha matte.
Uint8List confidencesToMask(List<double> conf, int mw, int mh, int outW, int outH) {
  final f = Float32List(mw * mh);
  for (var i = 0; i < f.length && i < conf.length; i++) {
    final c = conf[i];
    // Smoothstep 0.3..0.7 sharpens the matte while keeping soft hair edges.
    final t = ((c - 0.3) / 0.4).clamp(0.0, 1.0).toDouble();
    f[i] = t * t * (3 - 2 * t);
  }
  final r = (mw == outW && mh == outH) ? f : resizeF(f, mw, mh, outW, outH);
  final out = Uint8List(outW * outH);
  for (var i = 0; i < out.length; i++) {
    out[i] = clamp255(r[i] * 255);
  }
  return out;
}

class PortraitAdjust {
  final double brightness, contrast, saturation, warmth, sharpen, denoise;
  const PortraitAdjust({this.brightness = 0, this.contrast = 0, this.saturation = 0, this.warmth = 0, this.sharpen = 0, this.denoise = 0});
  PortraitAdjust copyWith({double? brightness, double? contrast, double? saturation, double? warmth, double? sharpen, double? denoise}) =>
      PortraitAdjust(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        sharpen: sharpen ?? this.sharpen,
        denoise: denoise ?? this.denoise,
      );
  bool get isNeutral => brightness == 0 && contrast == 0 && saturation == 0 && warmth == 0 && sharpen == 0 && denoise == 0;
}

/// Global, identity-preserving colour corrections (no facial reshaping,
/// no skin smoothing beyond a mild optional denoise).
void adjustPortrait(Rgb im, PortraitAdjust a) {
  if (a.denoise > 0) {
    final w = im.width, h = im.height, d = im.data;
    final ch = Uint8List(w * h);
    for (var c = 0; c < 3; c++) {
      for (var i = 0, j = c; i < ch.length; i++, j += 3) {
        ch[i] = d[j];
      }
      final b = boxBlurU8(ch, w, h, 1);
      for (var i = 0, j = c; i < ch.length; i++, j += 3) {
        d[j] = clamp255(ch[i] * (1 - a.denoise * 0.6) + b[i] * a.denoise * 0.6);
      }
    }
  }
  if (a.brightness != 0 || a.contrast != 0) applyLut(im, toneLut(brightness: a.brightness, contrast: a.contrast * 0.6));
  if (a.saturation != 0) adjustSaturation(im, a.saturation * 0.6);
  if (a.warmth != 0) {
    final d = im.data;
    for (var j = 0; j < d.length; j += 3) {
      d[j] = clamp255(d[j] * (1 + a.warmth * 0.08));
      d[j + 2] = clamp255(d[j + 2] * (1 - a.warmth * 0.08));
    }
  }
  if (a.sharpen > 0) sharpen(im, a.sharpen);
}

/// Composites the subject over a flat background using an alpha [mask].
void compositeBackground(Rgb im, Uint8List mask, int bgArgb) {
  final br = (bgArgb >> 16) & 0xFF, bgc = (bgArgb >> 8) & 0xFF, bb = bgArgb & 0xFF;
  final d = im.data;
  for (var i = 0, j = 0; i < mask.length; i++, j += 3) {
    final a = mask[i];
    if (a == 255) continue;
    d[j] = (d[j] * a + br * (255 - a)) ~/ 255;
    d[j + 1] = (d[j + 1] * a + bgc * (255 - a)) ~/ 255;
    d[j + 2] = (d[j + 2] * a + bb * (255 - a)) ~/ 255;
  }
}

// ---------------------------------------------------------------------------
// Isolate entry points
// ---------------------------------------------------------------------------

/// Normalises the selected portrait into a working JPEG (EXIF applied,
/// longest side <= [maxDim]). Returns (width, height).
Future<(int, int)> preparePortraitSource(String src, String out, {int maxDim = 3200}) => Isolate.run(() {
      final rgb = loadRgb(src);
      final (w, h) = fitWithin(rgb.width, rgb.height, maxDim);
      final small = resizeRgb(rgb, w, h);
      writeAtomic(out, encodeJpeg(small, 95));
      return (w, h);
    });

/// Renders the cropped portrait at output resolution.
Future<void> renderCropFile(String src, PortraitCrop c, int outW, int outH, String out) => Isolate.run(() {
      final rgb = loadRgb(src);
      writeAtomic(out, encodeJpeg(renderCrop(rgb, c, outW, outH), 95));
    });

class ComposeInput {
  final String cropPath;
  final Uint8List? mask; // null = keep original background
  final List<Map<String, dynamic>> strokes;
  final int bgArgb;
  final bool replaceBackground;
  final PortraitAdjust adjust;
  final String outPath;
  final bool png;
  const ComposeInput({
    required this.cropPath,
    required this.mask,
    required this.strokes,
    required this.bgArgb,
    required this.replaceBackground,
    required this.adjust,
    required this.outPath,
    this.png = false,
  });
}

/// Produces the final passport photo file.
Future<void> composePortrait(ComposeInput input) => Isolate.run(() {
      final rgb = loadRgb(input.cropPath);
      adjustPortrait(rgb, input.adjust);
      final m = input.mask;
      if (input.replaceBackground && m != null && m.length == rgb.pixels) {
        final mask = Uint8List.fromList(m);
        applyStrokes(mask, rgb.width, rgb.height, input.strokes.map(MaskStroke.fromJson).toList());
        final feathered = boxBlurU8(mask, rgb.width, rgb.height, 1);
        compositeBackground(rgb, feathered, input.bgArgb);
      }
      final bytes = input.png ? img.encodePng(rgbToImage(rgb)) : encodeJpeg(rgb, 96);
      writeAtomic(input.outPath, bytes);
    });

/// Writes a mask preview overlay (red = background) for the refine screen.
Future<Uint8List> maskOverlayPng(Uint8List mask, int w, int h, List<Map<String, dynamic>> strokes) => Isolate.run(() {
      final m = Uint8List.fromList(mask);
      applyStrokes(m, w, h, strokes.map(MaskStroke.fromJson).toList());
      final im = img.Image(width: w, height: h, numChannels: 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final a = 255 - m[y * w + x];
          im.setPixelRgba(x, y, 230, 40, 60, (a * 0.55).round());
        }
      }
      return img.encodePng(im);
    });

bool fileExists(String p) => File(p).existsSync();
