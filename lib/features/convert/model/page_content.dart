import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Text and images of one PDF page in display points (top-left origin,
/// page rotation applied). Produced by the PDF engine or by OCR; consumed
/// by the converters. Engine-neutral.
class PdfWord {
  final String text;
  final Rect box;
  final double size; // font size in points
  final bool bold;
  final bool italic;
  final int color; // ARGB
  final String font;
  final double? confidence; // OCR confidence (0..1); null for native text
  final int? line; // OCR: the engine's text line this word belongs to

  const PdfWord(this.text, this.box, {this.size = 10, this.bold = false, this.italic = false, this.color = 0xFF000000, this.font = '', this.confidence, this.line});

  bool get uncertain => confidence != null && confidence! < 0.6;
}

class PdfLine {
  final List<PdfWord> words; // left to right
  const PdfLine(this.words);

  Rect get box => words.map((w) => w.box).reduce((a, b) => a.expandToInclude(b));
  String get text => words.map((w) => w.text).join(' ');
  double get size {
    final s = words.map((w) => w.size).toList()..sort();
    return s[s.length ~/ 2];
  }

  bool get bold => words.every((w) => w.bold);
  bool get italic => words.every((w) => w.italic);
  int get color => words.first.color;
  String get font => words.first.font;
  double get baseline => words.map((w) => w.box.bottom).reduce(math.max);
}

class PdfImageBlock {
  final Rect box;
  final Uint8List png; // encoded PNG
  final int pixelWidth;
  final int pixelHeight;
  const PdfImageBlock(this.box, this.png, this.pixelWidth, this.pixelHeight);
}

/// A straight ruling line (table border) from the page's vector graphics.
class PdfRule {
  final Offset a;
  final Offset b;
  const PdfRule(this.a, this.b);
  bool get horizontal => (a.dy - b.dy).abs() < 1.5;
  bool get vertical => (a.dx - b.dx).abs() < 1.5;
  double get length => (b - a).distance;
}

class PageContent {
  final int index;
  final Size size;
  final List<PdfLine> lines; // top to bottom
  final List<PdfImageBlock> images;
  final List<PdfRule> rules;
  final bool fromOcr;
  final bool scanned; // image-only page (before OCR)

  const PageContent({required this.index, required this.size, required this.lines, this.images = const [], this.rules = const [], this.fromOcr = false, this.scanned = false});

  String get text => lines.map((l) => l.text).join('\n');
  bool get hasText => lines.isNotEmpty;
  int get uncertainWords => lines.fold(0, (n, l) => n + l.words.where((w) => w.uncertain).length);

  /// True when text sits in two or more columns side by side (a hint that
  /// reading order may not convert perfectly).
  bool get multiColumn {
    if (lines.length < 6) return false;
    final mid = size.width / 2;
    var left = 0, right = 0;
    for (final l in lines) {
      final b = l.box;
      if (b.right < mid - 4 && b.width > size.width * 0.15) left++;
      if (b.left > mid + 4 && b.width > size.width * 0.15) right++;
    }
    return left >= 3 && right >= 3;
  }
}

/// Groups words into lines (same baseline, reading order). Words are split
/// into separate lines when a horizontal gap is very large compared with the
/// font size (separate columns are kept apart).
List<PdfLine> groupWordsIntoLines(List<PdfWord> words) {
  final sorted = [...words]..sort((a, b) {
      final dy = a.box.center.dy - b.box.center.dy;
      if (dy.abs() > math.min(a.box.height, b.box.height) * 0.5) return dy.sign.toInt();
      return a.box.left.compareTo(b.box.left);
    });
  final rows = <List<PdfWord>>[];
  for (final w in sorted) {
    List<PdfWord>? row;
    for (final r in rows.reversed.take(4)) {
      final ref = r.last;
      final overlap = math.min(ref.box.bottom, w.box.bottom) - math.max(ref.box.top, w.box.top);
      if (overlap > math.min(ref.box.height, w.box.height) * 0.5) {
        row = r;
        break;
      }
    }
    if (row == null) {
      rows.add([w]);
    } else {
      row.add(w);
    }
  }
  final lines = <PdfLine>[];
  for (final r in rows) {
    r.sort((a, b) => a.box.left.compareTo(b.box.left));
    var cur = <PdfWord>[r.first];
    for (var i = 1; i < r.length; i++) {
      final gap = r[i].box.left - cur.last.box.right;
      if (gap > math.max(r[i].size, cur.last.size) * 4) {
        lines.add(PdfLine(cur));
        cur = [r[i]];
      } else {
        cur.add(r[i]);
      }
    }
    lines.add(PdfLine(cur));
  }
  lines.sort((a, b) {
    final dy = a.box.top - b.box.top;
    if (dy.abs() > 2) return dy.sign.toInt();
    return a.box.left.compareTo(b.box.left);
  });
  return lines;
}
