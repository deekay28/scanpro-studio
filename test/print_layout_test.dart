import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/units.dart';
import 'package:scanpro_studio/features/passport/print_layout.dart';

void main() {
  group('Unit conversions', () {
    test('mm <-> pt <-> px', () {
      expect(mmToPt(25.4), closeTo(72, 1e-9));
      expect(ptToMm(72), closeTo(25.4, 1e-9));
      expect(mmToPx(35, 600), closeTo(826.77, 0.01));
      expect(pxToMm(600, 600), closeTo(25.4, 1e-9));
    });
  });

  group('PrintLayoutEngine', () {
    const spec = SheetSpec(paper: PaperSizes.a4, photoWmm: 35, photoHmm: 45, marginMm: 5, gapMm: 2, copies: 8);

    test('8 passport photos on A4 form a 4x2 grid with exact sizes', () {
      final l = PrintLayoutEngine.compute(spec);
      expect(l.placed, 8);
      expect(l.cols, 4);
      expect(l.rows, 2);
      expect(l.capacity, 30); // 5 x 6
      for (final c in l.cells) {
        expect(c.w, 35);
        expect(c.h, 45);
        expect(c.x, greaterThanOrEqualTo(5));
        expect(c.y, greaterThanOrEqualTo(5));
        expect(c.right, lessThanOrEqualTo(210 - 5 + 1e-9));
        expect(c.bottom, lessThanOrEqualTo(297 - 5 + 1e-9));
      }
      expect(l.hasOverlap, isFalse);
      // Gaps between neighbours are exactly the requested gap.
      expect(l.cells[1].x - l.cells[0].right, closeTo(2, 1e-9));
      expect(l.cells[4].y - l.cells[0].bottom, closeTo(2, 1e-9));
    });

    test('block is centred horizontally', () {
      final l = PrintLayoutEngine.compute(spec);
      final left = l.cells.first.x;
      final right = 210 - l.cells.map((c) => c.right).reduce((a, b) => a > b ? a : b);
      expect(left, closeTo(right, 1e-9));
    });

    test('fill sheet uses full capacity', () {
      final l = PrintLayoutEngine.compute(spec.copyWith(clearCopies: true));
      expect(l.placed, 30);
      expect(l.hasOverlap, isFalse);
    });

    test('4x6 inch: portrait fits 6, landscape fits 8, optimiser picks landscape', () {
      const s = SheetSpec(paper: PaperSizes.photo4x6, photoWmm: 35, photoHmm: 45, marginMm: 3, gapMm: 2);
      expect(PrintLayoutEngine.compute(s).capacity, 6);
      expect(PrintLayoutEngine.compute(s.copyWith(landscape: true)).capacity, 8);
      expect(PrintLayoutEngine.bestLandscape(s), isTrue);
    });

    test('requesting more than capacity places capacity and warns', () {
      final l = PrintLayoutEngine.compute(spec.copyWith(copies: 40));
      expect(l.placed, 30);
      expect(l.fitsAll, isFalse);
      expect(l.warnings, isNotEmpty);
      expect(l.sheetsFor(40), 2);
    });

    test('photo that does not fit is never shrunk', () {
      final l = PrintLayoutEngine.compute(const SheetSpec(paper: PaperSizes.photo4x6, photoWmm: 120, photoHmm: 170));
      expect(l.capacity, 0);
      expect(l.cells, isEmpty);
      expect(l.warnings.first, contains('does not fit'));
    });

    test('manual grid larger than possible is reduced with warning', () {
      final l = PrintLayoutEngine.compute(spec.copyWith(rows: 10, cols: 10, copies: 100));
      expect(l.cols, 5);
      expect(l.rows, 6);
      expect(l.warnings, isNotEmpty);
      expect(l.hasOverlap, isFalse);
    });

    test('2x2 inch on letter', () {
      const s = SheetSpec(paper: PaperSizes.letter, photoWmm: 50.8, photoHmm: 50.8, marginMm: 6, gapMm: 3, copies: 6);
      final l = PrintLayoutEngine.compute(s);
      expect(l.placed, 6);
      for (final c in l.cells) {
        expect(c.w, 50.8);
        expect(c.h, 50.8);
      }
    });

    test('usage ratio and unused area are consistent', () {
      final l = PrintLayoutEngine.compute(spec);
      expect(l.usedAreaMm2, closeTo(8 * 35 * 45, 1e-6));
      expect(l.unusedAreaMm2 + l.usedAreaMm2, closeTo(210 * 297, 1e-6));
      expect(l.usageRatio, closeTo(8 * 35 * 45 / (210 * 297), 1e-9));
    });

    test('effective DPI and required pixels', () {
      expect(PrintLayoutEngine.effectiveDpi(1063, 45), closeTo(600, 1));
      final (w, h) = PrintLayoutEngine.requiredPixels(35, 45, 300);
      expect(w, 414);
      expect(h, 532);
    });
  });

  group('PaperSize', () {
    test('orientation', () {
      final l = PaperSizes.a4.oriented(true);
      expect(l.widthMm, 297);
      expect(l.heightMm, 210);
      final p = l.oriented(false);
      expect(p.widthMm, 210);
    });

    test('aspect detection', () {
      expect(PaperSizes.detectFromAspect(297 / 210)?.id, 'a4');
      expect(PaperSizes.detectFromAspect(279.4 / 215.9)?.id, 'letter');
      expect(PaperSizes.detectFromAspect(1.0), isNull);
    });
  });
}
