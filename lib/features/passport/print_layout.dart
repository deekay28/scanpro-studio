import 'dart:math' as math;

import '../../core/units.dart';

/// Axis-aligned rectangle in millimetres.
class MmRect {
  final double x, y, w, h;
  const MmRect(this.x, this.y, this.w, this.h);
  double get right => x + w;
  double get bottom => y + h;
  bool overlaps(MmRect o, {double eps = 1e-6}) =>
      x < o.right - eps && o.x < right - eps && y < o.bottom - eps && o.y < bottom - eps;
  @override
  String toString() => 'MmRect(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${w.toStringAsFixed(2)}×${h.toStringAsFixed(2)})';
}

/// Inputs for a photo print sheet. Every value is a physical measurement.
class SheetSpec {
  final PaperSize paper;
  final bool landscape;
  final double photoWmm;
  final double photoHmm;
  final double marginMm; // printer-safe margin on every side
  final double gapMm; // space between photos (cut gutter)
  final int? copies; // null = as many as fit
  final int? rows; // manual layout (optional)
  final int? cols; // manual layout (optional)
  final bool cutLines;
  final bool cropMarks;
  final double borderMm; // white border drawn inside each photo cell
  final bool labels; // dimension labels + scale bar in the margin

  const SheetSpec({
    required this.paper,
    this.landscape = false,
    required this.photoWmm,
    required this.photoHmm,
    this.marginMm = 5,
    this.gapMm = 2,
    this.copies,
    this.rows,
    this.cols,
    this.cutLines = true,
    this.cropMarks = false,
    this.borderMm = 0,
    this.labels = true,
  });

  SheetSpec copyWith({
    PaperSize? paper,
    bool? landscape,
    double? photoWmm,
    double? photoHmm,
    double? marginMm,
    double? gapMm,
    int? copies,
    bool clearCopies = false,
    int? rows,
    int? cols,
    bool clearManual = false,
    bool? cutLines,
    bool? cropMarks,
    double? borderMm,
    bool? labels,
  }) =>
      SheetSpec(
        paper: paper ?? this.paper,
        landscape: landscape ?? this.landscape,
        photoWmm: photoWmm ?? this.photoWmm,
        photoHmm: photoHmm ?? this.photoHmm,
        marginMm: marginMm ?? this.marginMm,
        gapMm: gapMm ?? this.gapMm,
        copies: clearCopies ? null : (copies ?? this.copies),
        rows: clearManual ? null : (rows ?? this.rows),
        cols: clearManual ? null : (cols ?? this.cols),
        cutLines: cutLines ?? this.cutLines,
        cropMarks: cropMarks ?? this.cropMarks,
        borderMm: borderMm ?? this.borderMm,
        labels: labels ?? this.labels,
      );
}

class SheetLayout {
  final double pageWmm;
  final double pageHmm;
  final List<MmRect> cells;
  final int rows;
  final int cols;
  final int capacity; // max photos that fit with these settings
  final int requested;
  final List<String> warnings;

  const SheetLayout({
    required this.pageWmm,
    required this.pageHmm,
    required this.cells,
    required this.rows,
    required this.cols,
    required this.capacity,
    required this.requested,
    required this.warnings,
  });

  int get placed => cells.length;
  double get pageAreaMm2 => pageWmm * pageHmm;
  double get usedAreaMm2 => cells.fold(0.0, (s, c) => s + c.w * c.h);
  double get unusedAreaMm2 => pageAreaMm2 - usedAreaMm2;
  double get usageRatio => pageAreaMm2 == 0 ? 0 : usedAreaMm2 / pageAreaMm2;
  bool get fitsAll => placed >= requested;

  /// Sheets needed to print [total] photos with this layout.
  int sheetsFor(int total) => capacity == 0 ? 0 : (total / capacity).ceil();

  bool get hasOverlap {
    for (var i = 0; i < cells.length; i++) {
      for (var j = i + 1; j < cells.length; j++) {
        if (cells[i].overlaps(cells[j])) return true;
      }
    }
    return false;
  }
}

class PrintLayoutEngine {
  /// Max columns/rows of [photo] size that fit in [usable] with [gap].
  static int fitCount(double usable, double photo, double gap) {
    if (photo <= 0 || usable < photo) return 0;
    return ((usable + gap) / (photo + gap) + 1e-9).floor();
  }

  /// Computes a layout. Photos are never resized: if they do not fit, fewer
  /// are placed and a warning is returned.
  static SheetLayout compute(SheetSpec s) {
    final page = s.paper.oriented(s.landscape);
    final pw = page.widthMm, ph = page.heightMm;
    final warnings = <String>[];
    final usableW = pw - 2 * s.marginMm, usableH = ph - 2 * s.marginMm;
    final maxCols = fitCount(usableW, s.photoWmm, s.gapMm);
    final maxRows = fitCount(usableH, s.photoHmm, s.gapMm);
    final capacity = maxCols * maxRows;
    if (capacity == 0) {
      warnings.add('A ${_f(s.photoWmm)}×${_f(s.photoHmm)} mm photo does not fit on ${page.name} with ${_f(s.marginMm)} mm margins.');
      return SheetLayout(pageWmm: pw, pageHmm: ph, cells: const [], rows: 0, cols: 0, capacity: 0, requested: s.copies ?? 0, warnings: warnings);
    }
    int cols, rows, count;
    if (s.rows != null && s.cols != null) {
      cols = s.cols!;
      rows = s.rows!;
      if (cols > maxCols || rows > maxRows) {
        warnings.add('Manual grid $rows×$cols does not fit; the maximum is $maxRows×$maxCols. Reduced to fit.');
        cols = math.min(cols, maxCols);
        rows = math.min(rows, maxRows);
      }
      count = math.min(s.copies ?? rows * cols, rows * cols);
      if (s.copies != null && s.copies! > rows * cols) {
        warnings.add('Only ${rows * cols} of ${s.copies} photos fit in a $rows×$cols grid.');
      }
    } else {
      final requested = s.copies ?? capacity;
      count = math.min(requested, capacity);
      if (requested > capacity) {
        warnings.add('Only $capacity photos fit on one ${page.name} sheet; ${requested - capacity} will need another sheet.');
      }
      cols = math.min(maxCols, math.max(1, count));
      rows = (count / cols).ceil();
      // Use the fewest columns that keep the same number of rows (compact,
      // fully filled rows: e.g. 8 photos -> 4×2 instead of 5+3).
      while (cols > 1 && (count / (cols - 1)).ceil() == rows) {
        cols--;
      }
    }
    final blockW = cols * s.photoWmm + (cols - 1) * s.gapMm;
    final blockH = rows * s.photoHmm + (rows - 1) * s.gapMm;
    // Centre the block (equal outer margins, never below the safe margin).
    final x0 = math.max(s.marginMm, (pw - blockW) / 2);
    final y0 = math.max(s.marginMm, (ph - blockH) / 2);
    final cells = <MmRect>[];
    for (var i = 0; i < count; i++) {
      final r = i ~/ cols, c = i % cols;
      cells.add(MmRect(x0 + c * (s.photoWmm + s.gapMm), y0 + r * (s.photoHmm + s.gapMm), s.photoWmm, s.photoHmm));
    }
    if (s.gapMm < 1 && (s.cutLines || s.cropMarks)) {
      warnings.add('Gaps under 1 mm make cutting difficult.');
    }
    if (s.marginMm < 3) {
      warnings.add('Many printers cannot print closer than 3–5 mm to the paper edge.');
    }
    return SheetLayout(
      pageWmm: pw,
      pageHmm: ph,
      cells: cells,
      rows: rows,
      cols: cols,
      capacity: capacity,
      requested: s.copies ?? capacity,
      warnings: warnings,
    );
  }

  /// Compares portrait and landscape paper and returns the orientation that
  /// fits more photos (portrait on ties).
  static bool bestLandscape(SheetSpec s) {
    final p = compute(s.copyWith(landscape: false, clearManual: true, clearCopies: true)).capacity;
    final l = compute(s.copyWith(landscape: true, clearManual: true, clearCopies: true)).capacity;
    return l > p;
  }

  /// Minimum source pixels (shorter, longer) for a photo at [dpi].
  static (int, int) requiredPixels(double wMm, double hMm, int dpi) =>
      (mmToPx(wMm, dpi.toDouble()).ceil(), mmToPx(hMm, dpi.toDouble()).ceil());

  /// Effective DPI the user's crop will print at.
  static double effectiveDpi(int cropPixelHeight, double photoHmm) => cropPixelHeight / (photoHmm / mmPerInch);

  static String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
