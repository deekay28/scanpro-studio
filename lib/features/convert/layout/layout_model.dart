import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'font_metrics_data.dart';

/// Positioned page layout used to rebuild a page as an editable Word page.
/// Coordinates are PDF points from the page's top-left corner. Produced from
/// native PDF content ([nativeLayout]) or from a scanned page through OCR and
/// image analysis ([analyzeScannedPage]); written by [writeLayoutDocx].

class LWord {
  final String text;
  final Rect box;
  double size; // font size in points
  bool bold;
  final bool italic;
  bool underline;
  final int color; // ARGB
  final String font; // Word font family
  final double? confidence; // OCR confidence (0..1); null for native text

  LWord(this.text, this.box, {this.size = 10, this.bold = false, this.italic = false, this.underline = false, this.color = 0xFF000000, this.font = 'Arial', this.confidence});

  bool get uncertain => confidence != null && confidence! < 0.6;
}

class LLine {
  final List<LWord> words; // left to right
  LLine(this.words);

  Rect get box => words.map((w) => w.box).reduce((a, b) => a.expandToInclude(b));
  String get text => words.map((w) => w.text).join(' ');
  double get size {
    final s = words.map((w) => w.size).toList()..sort();
    return s[s.length ~/ 2];
  }

  /// Baseline estimate: bottoms of words without descenders.
  /// Baseline estimate from the bottoms of words without descenders,
  /// cross-checked with the tops of the words (cap or x-height above the
  /// baseline) so a box stretched by an underline or smudge doesn't move it.
  double get baseline {
    // Words read with very low confidence often have wrong boxes.
    // Boxes taller than a line of text of this size (ascender to descender
    // is about 0.93 em) were stretched by something below the text.
    final plausible = words.where((w) => w.size <= 0 || w.box.height <= w.size * 1.2).toList();
    if (plausible.isEmpty && size > 0) {
      final t = words.map((w) => w.box.top).toList()..sort();
      return t[t.length ~/ 2] + size * 0.72;
    }
    final good = plausible.where((w) => (w.confidence ?? 1) >= 0.3).toList();
    final ws = good.isEmpty ? plausible : good;
    final plain = ws.where((w) => !RegExp(r'[gjpqy,;()\[\]{}_|@$]').hasMatch(w.text)).toList();
    double fromBottom;
    if (plain.isNotEmpty) {
      final b = plain.map((w) => w.box.bottom).toList()..sort();
      fromBottom = b[(b.length - 1) ~/ 2];
    } else {
      final b = ws.map((w) => w.box.bottom - w.size * 0.21).toList()..sort();
      fromBottom = b[(b.length - 1) ~/ 2];
    }
    final tops = <double>[
      for (final w in ws)
        if (w.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').isNotEmpty)
          w.box.top + w.size * (RegExp(r'[A-Z0-9bdfhklt]').hasMatch(w.text) ? 0.72 : 0.52),
    ]..sort();
    if (tops.isEmpty || size <= 0) return fromBottom;
    final fromTop = tops[tops.length ~/ 2];
    return (fromBottom - fromTop).abs() > size * 0.25 ? fromTop : fromBottom;
  }
}

class LCell {
  final int row, col;
  int rowSpan, colSpan;
  final List<LLine> lines = [];
  int? shade; // ARGB fill
  LCell(this.row, this.col, {this.rowSpan = 1, this.colSpan = 1});
}

class LTable {
  final List<double> colX; // column boundaries, left to right (n + 1)
  final List<double> rowY; // row boundaries, top to bottom (m + 1)
  final List<LCell> cells; // top-left cell of each (merged) cell
  final double borderWidth; // points
  final int borderColor; // ARGB
  final bool borders;
  LTable(this.colX, this.rowY, this.cells, {this.borderWidth = 0.75, this.borderColor = 0xFF000000, this.borders = true});

  Rect get box => Rect.fromLTRB(colX.first, rowY.first, colX.last, rowY.last);
  int get columns => colX.length - 1;
  int get rows => rowY.length - 1;
}

enum GraphicKind { qrCode, stamp, signature, photo, logo, graphic, pageImage }

class LGraphic {
  final Rect box;
  final Uint8List bytes;
  final String ext; // png | jpeg
  final int pixelWidth, pixelHeight;
  final GraphicKind kind;
  LGraphic(this.box, this.bytes, this.ext, this.pixelWidth, this.pixelHeight, {this.kind = GraphicKind.graphic});
}

/// A filled band behind text (e.g. a grey heading bar).
class LShade {
  final Rect box;
  final int color; // ARGB
  LShade(this.box, this.color);
}

class LayoutPage {
  final Size size;
  final List<LLine> lines; // outside tables and shades
  final List<LTable> tables;
  final List<LGraphic> graphics;
  final List<LShade> shades;
  final List<String> warnings;

  /// Faithful mode: the whole page as one image behind everything.
  final LGraphic? background;
  final bool fromScan;

  /// Scans only: regions (pixels of the analysed image) that look like text
  /// but where OCR found no words; they can be read again.
  List<Rect> unread = const [];

  LayoutPage(this.size, {List<LLine>? lines, List<LTable>? tables, List<LGraphic>? graphics, List<LShade>? shades, List<String>? warnings, this.background, this.fromScan = false})
      : lines = lines ?? [],
        tables = tables ?? [],
        graphics = graphics ?? [],
        shades = shades ?? [],
        warnings = warnings ?? [];

  String get text => [
        ...lines.map((l) => l.text),
        for (final t in tables)
          for (final c in t.cells) ...c.lines.map((l) => l.text),
      ].join('\n');
}

// ---------------------------------------------------------------------------
// Text measurement
// ---------------------------------------------------------------------------

final _index = {for (var i = 0; i < fontCodes.length; i++) fontCodes[i]: i};

bool isSerifFont(String family) {
  final f = family.toLowerCase();
  return f.contains('times') || f.contains('serif') && !f.contains('sans') || f.contains('georgia') || f.contains('garamond') || f.contains('cambria') || f.contains('book');
}

/// Whether [textAdvance] knows this font's widths (Arial, Helvetica, Times
/// and their metric-compatible equivalents).
bool hasMetrics(String family) {
  final f = family.toLowerCase();
  return f == 'arial' || f.startsWith('helvetica') || f.startsWith('liberation') || f == 'arimo' || f == 'tinos' || f.startsWith('times') || f == 'freesans';
}

/// Width of [text] at 1 pt in an Arial- or Times-compatible font.
double textAdvance(String text, {bool bold = false, bool italic = false, bool serif = false}) {
  final table = serif
      ? (bold ? (italic ? serifBoldItalicWidths : serifBoldWidths) : (italic ? serifItalicWidths : serifWidths))
      : (bold ? (italic ? sansBoldItalicWidths : sansBoldWidths) : (italic ? sansItalicWidths : sansWidths));
  var w = 0;
  for (final r in text.runes) {
    final i = _index[r];
    w += i == null ? 556 : table[i];
  }
  return w / 1000;
}

/// Font size at which [text] spans [width] points.
double fitSize(String text, double width, {bool bold = false, bool italic = false, bool serif = false}) {
  final a = textAdvance(text, bold: bold, italic: italic, serif: serif);
  return a <= 0 ? 0 : width / a;
}

/// Rounds to the nearest half point.
double halfPoint(double v) => (v * 2).round() / 2;

double median(Iterable<double> v) {
  final l = v.toList()..sort();
  if (l.isEmpty) return 0;
  return l.length.isOdd ? l[l.length ~/ 2] : (l[l.length ~/ 2 - 1] + l[l.length ~/ 2]) / 2;
}

double clampD(double v, double lo, double hi) => math.max(lo, math.min(hi, v));
