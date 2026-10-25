import '../core/models.dart';
import 'image_ops.dart';

/// Applies a preset followed by manual adjustments. Returns a new or
/// mutated image (callers must not rely on the input being preserved).
Rgb applyFilters(Rgb input, PageEdit e) {
  var im = input;
  final w = im.width, h = im.height;
  switch (e.preset) {
    case FilterPreset.original: {
      break;
    }
    case FilterPreset.smartAuto: {
      autoLevels(im);
      adjustSaturation(im, 0.1);
      sharpen(im, 0.35);
    }
    case FilterPreset.documentColor: {
      normalizeIllumination(im, minRatio: 0.55);
      final lut = toneLut(contrast: 0.12, highlights: 0.25);
      applyLut(im, lut);
      adjustSaturation(im, 0.15);
      sharpen(im, 0.3);
    }
    case FilterPreset.vividColor: {
      normalizeIllumination(im, minRatio: 0.55);
      applyLut(im, toneLut(contrast: 0.18, highlights: 0.2));
      adjustSaturation(im, 0.45);
      sharpen(im, 0.3);
    }
    case FilterPreset.grayscale: {
      final g = toGray(im);
      autoLevelsGray(g);
      im = grayToRgb(g, w, h);
    }
    case FilterPreset.blackWhite: {
      final g = normalizedGray(im);
      final b = binarize(g, w, h, adaptive: e.adaptiveBw, offset: e.threshold);
      im = grayToRgb(b, w, h);
    }
    case FilterPreset.highContrastText: {
      final g = normalizedGray(im);
      final lut = List<int>.generate(256, (v) {
        var t = (v / 255 - 0.12) / 0.78;
        t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final s = t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
        return clamp255(s * 255);
      });
      for (var i = 0; i < g.length; i++) {
        g[i] = lut[g[i]];
      }
      sharpenGray(g, w, h, 0.4);
      im = grayToRgb(g, w, h);
    }
    case FilterPreset.fadedRecovery: {
      normalizeIllumination(im, minRatio: 0.5);
      localContrast(im, gain: 2.2);
      applyLut(im, toneLut(contrast: 0.15, shadows: -0.25));
      adjustSaturation(im, 0.2);
    }
    case FilterPreset.receipt: {
      final g = normalizedGray(im, minRatio: 0.5);
      final s = softBinarize(g, w, h, softness: 9, k: 0.12);
      im = grayToRgb(s, w, h);
    }
    case FilterPreset.photo: {
      grayWorldWhiteBalance(im, strength: 0.6);
      autoLevels(im, low: 0.01, high: 0.99);
      adjustVibrance(im, 0.3);
      sharpen(im, 0.2);
    }
    case FilterPreset.officialPreserve: {
      // Gentle lighting correction only; colours, stamps, seals and fine
      // strokes are left intact. No thresholding, no sharpening.
      normalizeIllumination(im, strength: 0.5, minRatio: 0.8);
    }
  }

  // Manual adjustments (B&W images only get tone adjustments).
  if (e.brightness != 0 || e.contrast != 0 || e.highlights != 0 || e.shadows != 0) {
    applyLut(im, toneLut(brightness: e.brightness, contrast: e.contrast, highlights: e.highlights, shadows: e.shadows));
  }
  if (e.saturation != 0 && !e.preset.usesThreshold) adjustSaturation(im, e.saturation);
  if (e.sharpness > 0 && !e.preset.usesThreshold) sharpen(im, e.sharpness * 1.5);
  return im;
}
