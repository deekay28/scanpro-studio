import 'dart:math' as math;
import 'dart:typed_data';

/// Packed 8-bit RGB image used by the processing pipeline. Pure Dart so it
/// runs inside background isolates and in unit tests.
class Rgb {
  final int width;
  final int height;
  final Uint8List data; // length = width * height * 3

  Rgb(this.width, this.height, this.data) {
    if (data.length != width * height * 3) {
      throw ArgumentError('RGB buffer size mismatch');
    }
  }

  factory Rgb.blank(int w, int h, [int fill = 255]) {
    final d = Uint8List(w * h * 3);
    if (fill != 0) d.fillRange(0, d.length, fill);
    return Rgb(w, h, d);
  }

  Rgb clone() => Rgb(width, height, Uint8List.fromList(data));
  int get pixels => width * height;
}

int clamp255(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// Luminance (BT.601) as 8-bit gray.
Uint8List toGray(Rgb im) {
  final n = im.pixels;
  final out = Uint8List(n);
  final d = im.data;
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    out[i] = (d[j] * 77 + d[j + 1] * 150 + d[j + 2] * 29) >> 8;
  }
  return out;
}

Rgb grayToRgb(Uint8List g, int w, int h) {
  final out = Uint8List(w * h * 3);
  for (var i = 0, j = 0; i < g.length; i++, j += 3) {
    final v = g[i];
    out[j] = v;
    out[j + 1] = v;
    out[j + 2] = v;
  }
  return Rgb(w, h, out);
}

/// Separable box blur with edge clamping (normalised by the actual window).
Float32List boxBlurF(Float32List src, int w, int h, int r) {
  if (r <= 0) return Float32List.fromList(src);
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  final prefix = Float64List(math.max(w, h) + 1);
  // Horizontal.
  for (var y = 0; y < h; y++) {
    final row = y * w;
    prefix[0] = 0;
    for (var x = 0; x < w; x++) {
      prefix[x + 1] = prefix[x] + src[row + x];
    }
    for (var x = 0; x < w; x++) {
      final a = x - r < 0 ? 0 : x - r;
      final b = x + r >= w ? w - 1 : x + r;
      tmp[row + x] = (prefix[b + 1] - prefix[a]) / (b - a + 1);
    }
  }
  // Vertical.
  for (var x = 0; x < w; x++) {
    prefix[0] = 0;
    for (var y = 0; y < h; y++) {
      prefix[y + 1] = prefix[y] + tmp[y * w + x];
    }
    for (var y = 0; y < h; y++) {
      final a = y - r < 0 ? 0 : y - r;
      final b = y + r >= h ? h - 1 : y + r;
      out[y * w + x] = (prefix[b + 1] - prefix[a]) / (b - a + 1);
    }
  }
  return out;
}

Uint8List boxBlurU8(Uint8List src, int w, int h, int r) {
  final f = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    f[i] = src[i].toDouble();
  }
  final b = boxBlurF(f, w, h, r);
  final out = Uint8List(src.length);
  for (var i = 0; i < src.length; i++) {
    out[i] = clamp255(b[i]);
  }
  return out;
}

/// Bilinear resize of a single-channel float image.
Float32List resizeF(Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  final sx = sw / dw, sy = sh / dh;
  for (var y = 0; y < dh; y++) {
    var fy = (y + 0.5) * sy - 0.5;
    if (fy < 0) fy = 0;
    var y0 = fy.floor();
    if (y0 > sh - 1) y0 = sh - 1;
    final y1 = y0 + 1 < sh ? y0 + 1 : y0;
    final wy = fy - y0;
    for (var x = 0; x < dw; x++) {
      var fx = (x + 0.5) * sx - 0.5;
      if (fx < 0) fx = 0;
      var x0 = fx.floor();
      if (x0 > sw - 1) x0 = sw - 1;
      final x1 = x0 + 1 < sw ? x0 + 1 : x0;
      final wx = fx - x0;
      final a = src[y0 * sw + x0], b = src[y0 * sw + x1];
      final c = src[y1 * sw + x0], d = src[y1 * sw + x1];
      out[y * dw + x] = (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy;
    }
  }
  return out;
}

/// Estimates the paper/background illumination of a document image.
/// Text and small marks are removed with a block-max + dilation, so the
/// result follows lighting gradients and shadows, not content.
Float32List estimateBackground(Uint8List gray, int w, int h, {double minRatio = 0.6}) {
  final f = math.max(1, (math.min(w, h) / 96).floor());
  final sw = (w / f).ceil(), sh = (h / f).ceil();
  var small = Float32List(sw * sh);
  for (var by = 0; by < sh; by++) {
    for (var bx = 0; bx < sw; bx++) {
      var m = 0;
      final y1 = math.min(h, (by + 1) * f), x1 = math.min(w, (bx + 1) * f);
      for (var y = by * f; y < y1; y++) {
        final row = y * w;
        for (var x = bx * f; x < x1; x++) {
          final v = gray[row + x];
          if (v > m) m = v;
        }
      }
      small[by * sw + bx] = m.toDouble();
    }
  }
  // Dilation (max filter) to suppress text lines and small dark regions.
  const dr = 2;
  final dil = Float32List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var m = 0.0;
      for (var yy = math.max(0, y - dr); yy <= math.min(sh - 1, y + dr); yy++) {
        for (var xx = math.max(0, x - dr); xx <= math.min(sw - 1, x + dr); xx++) {
          final v = small[yy * sw + xx];
          if (v > m) m = v;
        }
      }
      dil[y * sw + x] = m;
    }
  }
  small = boxBlurF(dil, sw, sh, 3);
  // Paper level = 95th percentile; limit how dark the background may be so
  // large photos/diagrams are not washed out.
  final sorted = Float32List.fromList(small)..sort();
  final paper = sorted[math.min(sorted.length - 1, (sorted.length * 0.95).floor())];
  final floor = math.max(24.0, paper * minRatio);
  for (var i = 0; i < small.length; i++) {
    if (small[i] < floor) small[i] = floor;
  }
  return resizeF(small, sw, sh, w, h);
}

/// Divides out uneven illumination. [strength] blends with the input
/// (0 = unchanged, 1 = full correction).
void normalizeIllumination(Rgb im, {double strength = 1.0, double minRatio = 0.6, double target = 248}) {
  final g = toGray(im);
  final bg = estimateBackground(g, im.width, im.height, minRatio: minRatio);
  final d = im.data;
  for (var i = 0, j = 0; i < bg.length; i++, j += 3) {
    final s = target / bg[i];
    final k = 1 + (s - 1) * strength;
    d[j] = clamp255(d[j] * k);
    d[j + 1] = clamp255(d[j + 1] * k);
    d[j + 2] = clamp255(d[j + 2] * k);
  }
}

Uint8List normalizedGray(Rgb im, {double minRatio = 0.55}) {
  final g = toGray(im);
  final bg = estimateBackground(g, im.width, im.height, minRatio: minRatio);
  final out = Uint8List(g.length);
  for (var i = 0; i < g.length; i++) {
    out[i] = clamp255(g[i] * 248 / bg[i]);
  }
  return out;
}

void applyLut(Rgb im, Uint8List lut) {
  final d = im.data;
  for (var i = 0; i < d.length; i++) {
    d[i] = lut[d[i]];
  }
}

void applyLutGray(Uint8List g, Uint8List lut) {
  for (var i = 0; i < g.length; i++) {
    g[i] = lut[g[i]];
  }
}

/// Builds a tone curve LUT from manual adjustments (all in -1..1).
Uint8List toneLut({double brightness = 0, double contrast = 0, double highlights = 0, double shadows = 0}) {
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    var x = v / 255.0;
    x += shadows * 0.45 * math.pow(1 - x, 3);
    x += highlights * 0.45 * math.pow(x, 3);
    x += brightness * 0.3;
    x = (x - 0.5) * (1 + contrast) + 0.5;
    lut[v] = clamp255(_clamp01(x) * 255);
  }
  return lut;
}

void adjustSaturation(Rgb im, double amount) {
  if (amount == 0) return;
  final d = im.data;
  final k = 1 + amount;
  for (var j = 0; j < d.length; j += 3) {
    final l = (d[j] * 77 + d[j + 1] * 150 + d[j + 2] * 29) >> 8;
    d[j] = clamp255(l + (d[j] - l) * k);
    d[j + 1] = clamp255(l + (d[j + 1] - l) * k);
    d[j + 2] = clamp255(l + (d[j + 2] - l) * k);
  }
}

/// Vibrance: boosts low-saturation pixels more than saturated ones.
void adjustVibrance(Rgb im, double amount) {
  final d = im.data;
  for (var j = 0; j < d.length; j += 3) {
    final r = d[j], g = d[j + 1], b = d[j + 2];
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
    final k = 1 + amount * (1 - sat);
    final l = (r * 77 + g * 150 + b * 29) >> 8;
    d[j] = clamp255(l + (r - l) * k);
    d[j + 1] = clamp255(l + (g - l) * k);
    d[j + 2] = clamp255(l + (b - l) * k);
  }
}

List<int> histogram(Uint8List g) {
  final h = List<int>.filled(256, 0);
  for (final v in g) {
    h[v]++;
  }
  return h;
}

int percentile(List<int> hist, int total, double p) {
  final target = total * p;
  var acc = 0;
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= target) return i;
  }
  return 255;
}

/// Contrast stretch based on luminance percentiles (keeps hue).
void autoLevels(Rgb im, {double low = 0.005, double high = 0.995}) {
  final g = toGray(im);
  final hist = histogram(g);
  final lo = percentile(hist, g.length, low);
  final hi = percentile(hist, g.length, high);
  if (hi - lo < 10) return;
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = clamp255((v - lo) * 255 / (hi - lo));
  }
  applyLut(im, lut);
}

void autoLevelsGray(Uint8List g, {double low = 0.005, double high = 0.995}) {
  final hist = histogram(g);
  final lo = percentile(hist, g.length, low);
  final hi = percentile(hist, g.length, high);
  if (hi - lo < 10) return;
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = clamp255((v - lo) * 255 / (hi - lo));
  }
  applyLutGray(g, lut);
}

/// Partial gray-world white balance.
void grayWorldWhiteBalance(Rgb im, {double strength = 0.6}) {
  final d = im.data;
  var sr = 0.0, sg = 0.0, sb = 0.0;
  for (var j = 0; j < d.length; j += 3) {
    sr += d[j];
    sg += d[j + 1];
    sb += d[j + 2];
  }
  final n = im.pixels;
  if (n == 0) return;
  final ar = sr / n, ag = sg / n, ab = sb / n;
  final avg = (ar + ag + ab) / 3;
  double gain(double a) => (1 + ((avg / math.max(a, 1)) - 1) * strength).clamp(0.8, 1.25).toDouble();
  final gr = gain(ar), gg = gain(ag), gb = gain(ab);
  for (var j = 0; j < d.length; j += 3) {
    d[j] = clamp255(d[j] * gr);
    d[j + 1] = clamp255(d[j + 1] * gg);
    d[j + 2] = clamp255(d[j + 2] * gb);
  }
}

/// Unsharp mask on each channel (3x3 box), [amount] 0..2.
void sharpen(Rgb im, double amount) {
  if (amount <= 0) return;
  final w = im.width, h = im.height, d = im.data;
  final ch = Uint8List(w * h);
  for (var c = 0; c < 3; c++) {
    for (var i = 0, j = c; i < ch.length; i++, j += 3) {
      ch[i] = d[j];
    }
    final b = boxBlurU8(ch, w, h, 1);
    for (var i = 0, j = c; i < ch.length; i++, j += 3) {
      d[j] = clamp255(ch[i] + amount * (ch[i] - b[i]));
    }
  }
}

void sharpenGray(Uint8List g, int w, int h, double amount) {
  if (amount <= 0) return;
  final b = boxBlurU8(g, w, h, 1);
  for (var i = 0; i < g.length; i++) {
    g[i] = clamp255(g[i] + amount * (g[i] - b[i]));
  }
}

/// Otsu's global threshold.
int otsuThreshold(Uint8List g) {
  final hist = histogram(g);
  final total = g.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, maxVar = -1.0, thr = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > maxVar) {
      maxVar = v;
      thr = t;
    }
  }
  return thr;
}

/// Sauvola adaptive thresholding computed with box filters.
/// Returns local thresholds per pixel. [k] typically 0.15..0.35.
Float32List sauvolaThresholds(Uint8List g, int w, int h, {int? radius, double k = 0.2}) {
  final r = radius ?? math.max(7, math.min(w, h) ~/ 50);
  final f = Float32List(g.length);
  final f2 = Float32List(g.length);
  for (var i = 0; i < g.length; i++) {
    final v = g[i].toDouble();
    f[i] = v;
    f2[i] = v * v;
  }
  final m = boxBlurF(f, w, h, r);
  final m2 = boxBlurF(f2, w, h, r);
  for (var i = 0; i < g.length; i++) {
    final mean = m[i];
    final s = math.sqrt(math.max(0, m2[i] - mean * mean));
    m[i] = mean * (1 + k * (s / 128.0 - 1));
  }
  return m;
}

/// Pure black & white. Adaptive (Sauvola on illumination-normalised gray)
/// preserves thin strokes and pencil; [offset] -1..1 makes it lighter/darker.
Uint8List binarize(Uint8List g, int w, int h, {bool adaptive = true, double offset = 0}) {
  final out = Uint8List(g.length);
  if (adaptive) {
    final k = (0.2 + offset * 0.12).clamp(0.05, 0.45).toDouble();
    final t = sauvolaThresholds(g, w, h, k: k);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] < t[i] ? 0 : 255;
    }
  } else {
    final t = (otsuThreshold(g) + offset * 60).clamp(1, 254);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] < t ? 0 : 255;
    }
  }
  return out;
}

/// Soft binarisation (anti-aliased) used by receipt mode.
Uint8List softBinarize(Uint8List g, int w, int h, {double softness = 10, double k = 0.15}) {
  final t = sauvolaThresholds(g, w, h, k: k);
  final out = Uint8List(g.length);
  for (var i = 0; i < g.length; i++) {
    final x = (g[i] - t[i]) / softness;
    out[i] = clamp255(255 / (1 + math.exp(-x)));
  }
  return out;
}

/// Local contrast enhancement for faded documents.
void localContrast(Rgb im, {double gain = 2.0}) {
  final w = im.width, h = im.height;
  final g = toGray(im);
  final f = Float32List(g.length);
  for (var i = 0; i < g.length; i++) {
    f[i] = g[i].toDouble();
  }
  final r = math.max(8, math.min(w, h) ~/ 30);
  final mean = boxBlurF(f, w, h, r);
  final d = im.data;
  for (var i = 0, j = 0; i < g.length; i++, j += 3) {
    final target = mean[i] + (g[i] - mean[i]) * gain;
    final k = (target + 1) / (g[i] + 1);
    d[j] = clamp255(d[j] * k);
    d[j + 1] = clamp255(d[j + 1] * k);
    d[j + 2] = clamp255(d[j + 2] * k);
  }
}

/// Rotates by an arbitrary small angle around the centre (same canvas size,
/// white fill). Used for deskew.
Rgb rotateFine(Rgb im, double degrees) {
  if (degrees.abs() < 0.01) return im;
  final w = im.width, h = im.height;
  final out = Rgb.blank(w, h);
  final a = degrees * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  final cx = (w - 1) / 2, cy = (h - 1) / 2;
  final s = im.data, o = out.data;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      final sx = ca * dx + sa * dy + cx;
      final sy = -sa * dx + ca * dy + cy;
      if (sx < 0 || sy < 0 || sx > w - 1 || sy > h - 1) continue;
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 + 1 < w ? x0 + 1 : x0, y1 = y0 + 1 < h ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * w + x0) * 3, i10 = (y0 * w + x1) * 3, i01 = (y1 * w + x0) * 3, i11 = (y1 * w + x1) * 3;
      final oi = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        final top = s[i00 + c] * (1 - fx) + s[i10 + c] * fx;
        final bot = s[i01 + c] * (1 - fx) + s[i11 + c] * fx;
        o[oi + c] = clamp255(top * (1 - fy) + bot * fy);
      }
    }
  }
  return out;
}

/// Rotates by a multiple of 90° clockwise.
Rgb rotate90s(Rgb im, int degrees) {
  final r = ((degrees % 360) + 360) % 360;
  if (r == 0) return im;
  final w = im.width, h = im.height, s = im.data;
  final nw = r == 180 ? w : h, nh = r == 180 ? h : w;
  final o = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int nx, ny;
      if (r == 90) {
        nx = h - 1 - y;
        ny = x;
      } else if (r == 180) {
        nx = w - 1 - x;
        ny = h - 1 - y;
      } else {
        nx = y;
        ny = w - 1 - x;
      }
      final si = (y * w + x) * 3, oi = (ny * nw + nx) * 3;
      o[oi] = s[si];
      o[oi + 1] = s[si + 1];
      o[oi + 2] = s[si + 2];
    }
  }
  return Rgb(nw, nh, o);
}

/// Area-average downscale (or bilinear upscale) of an RGB image.
Rgb resizeRgb(Rgb im, int dw, int dh) {
  if (dw == im.width && dh == im.height) return im;
  final sw = im.width, sh = im.height, s = im.data;
  final o = Uint8List(dw * dh * 3);
  if (dw <= sw && dh <= sh) {
    final fx = sw / dw, fy = sh / dh;
    for (var y = 0; y < dh; y++) {
      final y0 = (y * fy).floor(), y1 = math.max(y0 + 1, math.min(sh, ((y + 1) * fy).ceil()));
      for (var x = 0; x < dw; x++) {
        final x0 = (x * fx).floor(), x1 = math.max(x0 + 1, math.min(sw, ((x + 1) * fx).ceil()));
        var r = 0, g = 0, b = 0, n = 0;
        for (var yy = y0; yy < y1; yy++) {
          var si = (yy * sw + x0) * 3;
          for (var xx = x0; xx < x1; xx++) {
            r += s[si];
            g += s[si + 1];
            b += s[si + 2];
            si += 3;
            n++;
          }
        }
        final oi = (y * dw + x) * 3;
        o[oi] = r ~/ n;
        o[oi + 1] = g ~/ n;
        o[oi + 2] = b ~/ n;
      }
    }
  } else {
    for (var y = 0; y < dh; y++) {
      final fy = math.max(0.0, (y + 0.5) * sh / dh - 0.5);
      final y0 = math.min(sh - 1, fy.floor()), y1 = math.min(sh - 1, y0 + 1);
      final wy = fy - y0;
      for (var x = 0; x < dw; x++) {
        final fx = math.max(0.0, (x + 0.5) * sw / dw - 0.5);
        final x0 = math.min(sw - 1, fx.floor()), x1 = math.min(sw - 1, x0 + 1);
        final wx = fx - x0;
        final oi = (y * dw + x) * 3;
        for (var c = 0; c < 3; c++) {
          final a = s[(y0 * sw + x0) * 3 + c], b = s[(y0 * sw + x1) * 3 + c];
          final cc = s[(y1 * sw + x0) * 3 + c], d = s[(y1 * sw + x1) * 3 + c];
          o[oi + c] = clamp255((a * (1 - wx) + b * wx) * (1 - wy) + (cc * (1 - wx) + d * wx) * wy);
        }
      }
    }
  }
  return Rgb(dw, dh, o);
}

/// Fits (w,h) inside a box whose longest side is [maxDim].
(int, int) fitWithin(int w, int h, int maxDim) {
  final m = math.max(w, h);
  if (m <= maxDim) return (w, h);
  final s = maxDim / m;
  return (math.max(1, (w * s).round()), math.max(1, (h * s).round()));
}
