/// Physical unit helpers. All print geometry in this app is computed in
/// millimetres and only converted to PDF points or pixels at render time.
library;

const double mmPerInch = 25.4;
const double ptPerInch = 72.0;

double mmToPt(double mm) => mm / mmPerInch * ptPerInch;
double ptToMm(double pt) => pt / ptPerInch * mmPerInch;
double mmToPx(double mm, double dpi) => mm / mmPerInch * dpi;
double pxToMm(double px, double dpi) => px / dpi * mmPerInch;
double inchToMm(double inch) => inch * mmPerInch;

/// A paper (or page) size in millimetres, portrait orientation.
class PaperSize {
  final String id;
  final String name;
  final double widthMm;
  final double heightMm;
  const PaperSize(this.id, this.name, this.widthMm, this.heightMm);

  PaperSize oriented(bool landscape) {
    final w = landscape ? (widthMm > heightMm ? widthMm : heightMm) : (widthMm < heightMm ? widthMm : heightMm);
    final h = landscape ? (widthMm > heightMm ? heightMm : widthMm) : (widthMm < heightMm ? heightMm : widthMm);
    return PaperSize(id, name, w, h);
  }

  double get aspect => heightMm / widthMm;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'w': widthMm, 'h': heightMm};
  factory PaperSize.fromJson(Map<String, dynamic> j) =>
      PaperSize(j['id'] as String, j['name'] as String, (j['w'] as num).toDouble(), (j['h'] as num).toDouble());

  @override
  String toString() => '$name (${_fmt(widthMm)} × ${_fmt(heightMm)} mm)';

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class PaperSizes {
  static const a3 = PaperSize('a3', 'A3', 297, 420);
  static const a4 = PaperSize('a4', 'A4', 210, 297);
  static const a5 = PaperSize('a5', 'A5', 148, 210);
  static const letter = PaperSize('letter', 'Letter', 215.9, 279.4);
  static const legal = PaperSize('legal', 'Legal', 215.9, 355.6);
  static const photo4x6 = PaperSize('4x6', '4 × 6 in', 101.6, 152.4);
  static const photo5x7 = PaperSize('5x7', '5 × 7 in', 127, 177.8);
  static const photo35x5 = PaperSize('3.5x5', '3.5 × 5 in', 88.9, 127);

  /// Sizes offered for document PDFs.
  static const documentSizes = [a4, a5, a3, letter, legal];

  /// Sizes offered for photo print sheets.
  static const photoSheetSizes = [a4, photo4x6, photo5x7, photo35x5, letter, a5];

  static PaperSize byId(String id, {PaperSize fallback = a4}) {
    for (final p in [...documentSizes, ...photoSheetSizes]) {
      if (p.id == id) return p;
    }
    return fallback;
  }

  /// Returns the standard size whose aspect ratio matches [aspect]
  /// (height / width, portrait) within [tolerance], or null.
  static PaperSize? detectFromAspect(double aspect, {double tolerance = 0.035}) {
    final a = aspect < 1 ? 1 / aspect : aspect;
    const candidates = [a4, letter, legal];
    PaperSize? best;
    double bestDiff = double.infinity;
    for (final c in candidates) {
      final d = (c.aspect - a).abs() / c.aspect;
      if (d < bestDiff) {
        bestDiff = d;
        best = c;
      }
    }
    return bestDiff <= tolerance ? best : null;
  }

  /// Rough classification of the captured shape (used for hints only).
  static String describeAspect(double aspect) {
    final a = aspect < 1 ? 1 / aspect : aspect;
    final std = detectFromAspect(a);
    if (std != null) return std.name;
    if ((a - 1.586).abs() < 0.06) return 'ID card';
    if (a > 2.0) return 'Receipt';
    return 'Custom';
  }
}
