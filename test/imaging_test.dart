import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/models.dart';
import 'package:scanpro_studio/imaging/book.dart';
import 'package:scanpro_studio/imaging/edge_detect.dart';
import 'package:scanpro_studio/imaging/filters.dart';
import 'package:scanpro_studio/imaging/image_ops.dart';
import 'package:scanpro_studio/imaging/perspective.dart';
import 'package:scanpro_studio/imaging/processor.dart';
import 'package:scanpro_studio/imaging/quality.dart';

/// Draws a filled convex polygon into a gray buffer.
void fillPoly(Uint8List g, int w, int h, List<Pt> poly, int v) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var inside = true;
      for (var i = 0; i < poly.length; i++) {
        final a = poly[i], b = poly[(i + 1) % poly.length];
        final cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
        if (cross < 0) {
          inside = false;
          break;
        }
      }
      if (inside) g[y * w + x] = v;
    }
  }
}

Rgb grayImage(int w, int h, int v) => Rgb(w, h, Uint8List(w * h * 3)..fillRange(0, w * h * 3, v));

void main() {
  group('Homography & perspective', () {
    test('maps the four reference points exactly', () {
      final src = [const Pt(0, 0), const Pt(100, 0), const Pt(100, 50), const Pt(0, 50)];
      final dst = [const Pt(10, 5), const Pt(90, 12), const Pt(95, 60), const Pt(3, 55)];
      final h = Homography.fromPoints(src, dst);
      for (var i = 0; i < 4; i++) {
        final p = h.apply(src[i]);
        expect(p.x, closeTo(dst[i].x, 1e-6));
        expect(p.y, closeTo(dst[i].y, 1e-6));
      }
    });

    test('orderQuad returns TL, TR, BR, BL', () {
      final q = orderQuad([const Pt(90, 80), const Pt(10, 10), const Pt(10, 85), const Pt(95, 5)]);
      expect(q[0].x, 10);
      expect(q[0].y, 10);
      expect(q[1].x, 95);
      expect(q[2].x, 90);
      expect(q[3].y, 85);
    });

    test('warpPerspective rectifies a skewed white quad', () {
      const w = 200, h = 160;
      final g = Uint8List(w * h);
      final quad = [const Pt(40, 30), const Pt(170, 20), const Pt(180, 140), const Pt(30, 130)];
      fillPoly(g, w, h, quad, 255);
      final img = grayToRgb(g, w, h);
      final out = warpPerspective(img, quad, 100, 80);
      // Every interior pixel of the output should be white (allow edge AA).
      var white = 0;
      for (var y = 3; y < 77; y++) {
        for (var x = 3; x < 97; x++) {
          if (out.data[(y * 100 + x) * 3] > 200) white++;
        }
      }
      expect(white / (74 * 94), greaterThan(0.98));
    });

    test('subQuadHorizontal splits at the requested fraction', () {
      final q = [const Pt(0, 0), const Pt(200, 0), const Pt(200, 100), const Pt(0, 100)];
      final left = subQuadHorizontal(q, 0, 0.5);
      expect(left[1].x, closeTo(100, 1e-6));
      expect(left[2].x, closeTo(100, 1e-6));
    });
  });

  group('Document detection', () {
    test('finds a bright page on a dark background', () {
      const w = 240, h = 180;
      final g = Uint8List(w * h)..fillRange(0, w * h, 40);
      final quad = [const Pt(50, 30), const Pt(200, 40), const Pt(190, 160), const Pt(40, 150)];
      fillPoly(g, w, h, quad, 230);
      final d = detectDocumentQuad(g, w, h);
      expect(d, isNotNull);
      final q = d!.quad;
      for (var i = 0; i < 4; i++) {
        expect(q[i].x * (w - 1), closeTo(quad[i].x, 6));
        expect(q[i].y * (h - 1), closeTo(quad[i].y, 6));
      }
      expect(d.touchesBorder, isFalse);
    });

    test('returns null for a flat image (fallback to manual crop)', () {
      const w = 120, h = 90;
      final g = Uint8List(w * h)..fillRange(0, w * h, 128);
      expect(detectDocumentQuad(g, w, h), isNull);
    });
  });

  group('Quality checks', () {
    test('blur lowers Laplacian variance', () {
      const w = 128, h = 128;
      final g = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          g[y * w + x] = ((x ~/ 4 + y ~/ 4) % 2 == 0) ? 0 : 255;
        }
      }
      final sharp = laplacianVariance(g, w, h);
      final blurred = laplacianVariance(boxBlurU8(g, w, h, 3), w, h);
      expect(blurred, lessThan(sharp / 4));
    });

    test('dHash detects near duplicates and distinguishes different images', () {
      const w = 90, h = 80;
      final a = Uint8List(w * h), b = Uint8List(w * h), c = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          a[y * w + x] = (x * 255 ~/ w);
          b[y * w + x] = math.min(255, (x * 255 ~/ w) + 6); // slightly brighter copy
          c[y * w + x] = 255 - (x * 255 ~/ w); // reversed gradient
        }
      }
      final ha = dHash(a, w, h), hb = dHash(b, w, h), hc = dHash(c, w, h);
      expect(isDuplicateHash(ha, hb), isTrue);
      expect(isDuplicateHash(ha, hc), isFalse);
    });

    test('flags dark and overexposed images', () {
      final dark = analyzeQuality(grayImage(200, 200, 20), sourceWidth: 3000, sourceHeight: 4000);
      expect(dark.flags(), contains(QualityFlag.dark));
      final bright = analyzeQuality(grayImage(200, 200, 254), sourceWidth: 3000, sourceHeight: 4000);
      expect(bright.flags(), contains(QualityFlag.overexposed));
    });
  });

  group('Filters', () {
    Rgb sample() {
      const w = 160, h = 120;
      final im = Rgb.blank(w, h, 0);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          // Paper with a lighting gradient.
          final paper = 170 + (x * 60 ~/ w);
          im.data[i] = paper;
          im.data[i + 1] = paper;
          im.data[i + 2] = paper;
        }
      }
      // Dark text line (1 px thin).
      for (var x = 20; x < 140; x++) {
        final i = (60 * w + x) * 3;
        im.data[i] = 40;
        im.data[i + 1] = 40;
        im.data[i + 2] = 40;
      }
      // Red stamp block.
      for (var y = 80; y < 100; y++) {
        for (var x = 100; x < 130; x++) {
          final i = (y * w + x) * 3;
          im.data[i] = 200;
          im.data[i + 1] = 30;
          im.data[i + 2] = 40;
        }
      }
      return im;
    }

    test('every preset runs and keeps dimensions', () {
      for (final p in FilterPreset.values) {
        final out = applyFilters(sample(), PageEdit(preset: p));
        expect(out.width, 160, reason: p.name);
        expect(out.height, 120, reason: p.name);
      }
    });

    test('Original preset is the identity', () {
      final s = sample();
      final out = applyFilters(s.clone(), const PageEdit());
      expect(out.data, s.data);
    });

    test('B&W outputs only black and white and keeps a 1 px line', () {
      final out = applyFilters(sample(), const PageEdit(preset: FilterPreset.blackWhite));
      expect(out.data.every((v) => v == 0 || v == 255), isTrue);
      var black = 0;
      for (var x = 30; x < 130; x++) {
        if (out.data[(60 * 160 + x) * 3] == 0) black++;
      }
      expect(black, greaterThan(90));
      // Paper (with lighting gradient) becomes white.
      expect(out.data[(20 * 160 + 10) * 3], 255);
      expect(out.data[(20 * 160 + 150) * 3], 255);
    });

    test('Official preservation keeps the red stamp red', () {
      final out = applyFilters(sample(), const PageEdit(preset: FilterPreset.officialPreserve));
      final i = (90 * 160 + 115) * 3;
      expect(out.data[i], greaterThan(150));
      expect(out.data[i + 1], lessThan(90));
    });

    test('Document colour whitens paper but keeps colour', () {
      final out = applyFilters(sample(), const PageEdit(preset: FilterPreset.documentColor));
      expect(out.data[(20 * 160 + 10) * 3], greaterThan(230));
      final i = (90 * 160 + 115) * 3;
      expect(out.data[i] - out.data[i + 1], greaterThan(80));
    });
  });

  group('Geometry ops', () {
    test('rotate90s swaps dimensions and maps pixels', () {
      final im = Rgb.blank(3, 2, 0);
      im.data[0] = 255; // pixel (0,0) red
      final r = rotate90s(im, 90);
      expect(r.width, 2);
      expect(r.height, 3);
      // (0,0) -> (h-1-0, 0) = (1, 0)
      expect(r.data[(0 * 2 + 1) * 3], 255);
    });

    test('estimateSkew recovers a known rotation', () {
      const w = 400, h = 300;
      final g = Uint8List(w * h)..fillRange(0, w * h, 255);
      for (var line = 30; line < 280; line += 20) {
        for (var x = 40; x < 360; x++) {
          for (var t = 0; t < 3; t++) {
            g[(line + t) * w + x] = 0;
          }
        }
      }
      final rotated = rotateFine(grayToRgb(g, w, h), 5);
      final angle = estimateSkew(toGray(rotated), w, h);
      expect(angle, closeTo(-5, 0.75));
      // Applying the estimate straightens the page again.
      final fixed = rotateFine(rotated, angle);
      expect(estimateSkew(toGray(fixed), w, h).abs(), lessThan(1.0));
    });

    test('renderEdit applies crop corners and rotation', () {
      final im = Rgb.blank(400, 300);
      final (out, _) = renderEdit(im, const PageEdit(corners: [0.1, 0.1, 0.9, 0.1, 0.9, 0.6, 0.1, 0.6], rotation: 90), 1000);
      // Quad is 320 x 150 px; rotated by 90 => 150 x 320.
      expect(out.width, 150);
      expect(out.height, 320);
    });
  });

  group('Book', () {
    test('detectSpine finds a dark gutter', () {
      const w = 300, h = 200;
      final g = Uint8List(w * h)..fillRange(0, w * h, 230);
      for (var y = 0; y < h; y++) {
        for (var x = 160; x < 168; x++) {
          g[y * w + x] = 90;
        }
      }
      final s = detectSpine(g, w, h);
      expect(s.position, closeTo(164 / 299, 0.02));
      expect(s.confidence, greaterThan(0.5));
    });

    test('no gutter falls back to the centre', () {
      const w = 300, h = 200;
      final g = Uint8List(w * h)..fillRange(0, w * h, 230);
      expect(detectSpine(g, w, h).position, 0.5);
    });

    test('splitSpread overlaps both pages at the spine', () {
      final (l, r) = splitSpread([0, 0, 1, 0, 1, 1, 0, 1], 0.5, overlap: 0.02);
      expect(l[2], closeTo(0.52, 1e-9)); // TR.x of left page
      expect(r[0], closeTo(0.48, 1e-9)); // TL.x of right page
    });

    test('flattenCurvedPage straightens curved page edges', () {
      const w = 300, h = 260;
      final im = Rgb.blank(w, h, 20);
      for (var x = 0; x < w; x++) {
        final t = (x - w / 2) / (w / 2);
        final top = (30 + 25 * t * t).round();
        final bottom = (230 - 25 * t * t).round();
        for (var y = top; y < bottom; y++) {
          final i = (y * w + x) * 3;
          im.data[i] = 235;
          im.data[i + 1] = 235;
          im.data[i + 2] = 235;
        }
      }
      final out = flattenCurvedPage(im);
      expect(out, isNotNull);
      // After flattening, first and last rows are page-coloured at the edges and centre.
      for (final x in [10, w ~/ 2, w - 10]) {
        expect(out!.data[(2 * w + x) * 3], greaterThan(150), reason: 'top row x=$x');
        expect(out.data[((out.height - 3) * w + x) * 3], greaterThan(150), reason: 'bottom row x=$x');
      }
    });

    test('quadratic fit recovers coefficients', () {
      final xs = [for (var i = 0; i < 20; i++) i.toDouble()];
      final ys = [for (final x in xs) 3 + 2 * x + 0.5 * x * x];
      final c = fitQuadratic(xs, ys)!;
      expect(c[0], closeTo(3, 1e-6));
      expect(c[1], closeTo(2, 1e-6));
      expect(c[2], closeTo(0.5, 1e-6));
    });
  });
}
