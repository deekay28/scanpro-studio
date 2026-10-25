import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../core/units.dart';
import '../../imaging/image_ops.dart';
import '../../imaging/processor.dart';
import 'print_layout.dart';

/// Renders print sheets using physical units. PDF output is vector-placed
/// in points (1 mm = 72/25.4 pt), so a 35 mm photo is exactly 35 mm when
/// printed at 100 % scale.
class SheetRenderer {
  static double pt(double mm) => mmToPt(mm);

  static Uint8List buildPdf(SheetSpec spec, SheetLayout layout, Uint8List photoJpeg, {String? title, String? photoLabel}) {
    final doc = sf.PdfDocument();
    try {
      doc.pageSettings.margins.all = 0;
      doc.documentInformation.title = title ?? 'Photo sheet';
      doc.documentInformation.creator = 'ScanPro Studio';
      final section = doc.sections!.add();
      section.pageSettings.margins.all = 0;
      section.pageSettings.size = Size(pt(layout.pageWmm), pt(layout.pageHmm));
      final page = section.pages.add();
      final g = page.graphics;
      final bmp = sf.PdfBitmap(photoJpeg);
      for (final c in layout.cells) {
        final b = spec.borderMm;
        g.drawImage(bmp, Rect.fromLTWH(pt(c.x + b), pt(c.y + b), pt(c.w - 2 * b), pt(c.h - 2 * b)));
      }
      final cutPen = sf.PdfPen(sf.PdfColor(150, 150, 150), width: 0.35)..dashStyle = sf.PdfDashStyle.dash;
      if (spec.cutLines) _drawCutLines(g, layout, cutPen);
      if (spec.cropMarks) _drawCropMarks(g, layout, spec.gapMm);
      if (spec.labels) _drawLabels(g, spec, layout, photoLabel);
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }

  static void _drawCutLines(sf.PdfGraphics g, SheetLayout l, sf.PdfPen pen) {
    if (l.cells.isEmpty) return;
    final xs = <double>{}, ys = <double>{};
    for (final c in l.cells) {
      xs..add(c.x)..add(c.right);
      ys..add(c.y)..add(c.bottom);
    }
    final minX = l.cells.map((c) => c.x).reduce(math.min), maxX = l.cells.map((c) => c.right).reduce(math.max);
    final minY = l.cells.map((c) => c.y).reduce(math.min), maxY = l.cells.map((c) => c.bottom).reduce(math.max);
    for (final x in xs) {
      g.drawLine(pen, Offset(pt(x), pt(math.max(0, minY - 3))), Offset(pt(x), pt(math.min(l.pageHmm, maxY + 3))));
    }
    for (final y in ys) {
      g.drawLine(pen, Offset(pt(math.max(0, minX - 3)), pt(y)), Offset(pt(math.min(l.pageWmm, maxX + 3)), pt(y)));
    }
  }

  static void _drawCropMarks(sf.PdfGraphics g, SheetLayout l, double gap) {
    final pen = sf.PdfPen(sf.PdfColor(0, 0, 0), width: 0.3);
    final len = math.max(1.0, math.min(3.0, gap / 2 + 1.5));
    for (final c in l.cells) {
      for (final (x, y, sx, sy) in [(c.x, c.y, -1, -1), (c.right, c.y, 1, -1), (c.x, c.bottom, -1, 1), (c.right, c.bottom, 1, 1)]) {
        g.drawLine(pen, Offset(pt(x), pt(y + sy * 0.5)), Offset(pt(x), pt(y + sy * len)));
        g.drawLine(pen, Offset(pt(x + sx * 0.5), pt(y)), Offset(pt(x + sx * len), pt(y)));
      }
    }
  }

  static void _drawLabels(sf.PdfGraphics g, SheetSpec spec, SheetLayout l, String? photoLabel) {
    if (l.cells.isEmpty) return;
    final font = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 6.5);
    final brush = sf.PdfSolidBrush(sf.PdfColor(110, 110, 110));
    final maxY = l.cells.map((c) => c.bottom).reduce(math.max);
    final room = l.pageHmm - maxY;
    if (room < 6) return; // not enough space; skip labels rather than overlap photos
    final y = maxY + math.min(room - 4.5, 3.0);
    final text = 'Photo ${_f(spec.photoWmm)} × ${_f(spec.photoHmm)} mm${photoLabel != null ? ' · $photoLabel' : ''} · Print at 100% / Actual size (no "Fit to page")';
    g.drawString(text, font, brush: brush, bounds: Rect.fromLTWH(pt(l.cells.first.x), pt(y), pt(l.pageWmm - l.cells.first.x - 2), pt(3)));
    // 30 mm scale bar with 5 mm ticks for checking printed scale.
    final barX = l.cells.first.x;
    final barY = y + 3.2;
    if (barY + 1.5 > l.pageHmm - 1) return;
    final pen = sf.PdfPen(sf.PdfColor(60, 60, 60), width: 0.3);
    g.drawLine(pen, Offset(pt(barX), pt(barY)), Offset(pt(barX + 30), pt(barY)));
    for (var i = 0; i <= 6; i++) {
      final x = barX + i * 5;
      g.drawLine(pen, Offset(pt(x), pt(barY)), Offset(pt(x), pt(barY - (i % 2 == 0 ? 1.2 : 0.7))));
    }
    g.drawString('30 mm', font, brush: brush, bounds: Rect.fromLTWH(pt(barX + 31), pt(barY - 1.6), pt(12), pt(3)));
  }

  static String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// Raster sheet (PNG or JPEG) at [dpi] with DPI metadata embedded so photo
  /// apps print it at the right physical size.
  static Future<Uint8List> buildRaster(SheetSpec spec, SheetLayout layout, String photoPath, {required int dpi, bool png = true}) {
    final cells = [for (final c in layout.cells) [c.x, c.y, c.w, c.h]];
    final pw = layout.pageWmm, ph = layout.pageHmm;
    final border = spec.borderMm, cut = spec.cutLines, marks = spec.cropMarks, gap = spec.gapMm;
    return Isolate.run(() {
      double px(double mm) => mm / 25.4 * dpi;
      final w = px(pw).round(), h = px(ph).round();
      final sheet = Rgb.blank(w, h);
      final photo = loadRgb(photoPath);
      for (final c in cells) {
        final x0 = px(c[0] + border).round(), y0 = px(c[1] + border).round();
        final x1 = px(c[0] + c[2] - border).round(), y1 = px(c[1] + c[3] - border).round();
        final cw = x1 - x0, ch = y1 - y0;
        if (cw <= 0 || ch <= 0) continue;
        final scaled = resizeRgb(photo, cw, ch);
        for (var y = 0; y < ch; y++) {
          final ty = y0 + y;
          if (ty < 0 || ty >= h) continue;
          final srcRow = y * cw * 3;
          final dstRow = (ty * w + x0) * 3;
          final len = math.min(cw, w - x0) * 3;
          if (len <= 0 || x0 < 0) continue;
          sheet.data.setRange(dstRow, dstRow + len, scaled.data, srcRow);
        }
      }
      void hLine(int y, int xa, int xb, int v, {bool dashed = false}) {
        if (y < 0 || y >= h) return;
        for (var x = math.max(0, xa); x <= math.min(w - 1, xb); x++) {
          if (dashed && ((x ~/ (dpi ~/ 25 + 1)) % 2 == 1)) continue;
          final i = (y * w + x) * 3;
          sheet.data[i] = v;
          sheet.data[i + 1] = v;
          sheet.data[i + 2] = v;
        }
      }

      void vLine(int x, int ya, int yb, int v, {bool dashed = false}) {
        if (x < 0 || x >= w) return;
        for (var y = math.max(0, ya); y <= math.min(h - 1, yb); y++) {
          if (dashed && ((y ~/ (dpi ~/ 25 + 1)) % 2 == 1)) continue;
          final i = (y * w + x) * 3;
          sheet.data[i] = v;
          sheet.data[i + 1] = v;
          sheet.data[i + 2] = v;
        }
      }

      if (cut && cells.isNotEmpty) {
        final xs = <double>{}, ys = <double>{};
        for (final c in cells) {
          xs..add(c[0])..add(c[0] + c[2]);
          ys..add(c[1])..add(c[1] + c[3]);
        }
        final minX = cells.map((c) => c[0]).reduce(math.min), maxX = cells.map((c) => c[0] + c[2]).reduce(math.max);
        final minY = cells.map((c) => c[1]).reduce(math.min), maxY = cells.map((c) => c[1] + c[3]).reduce(math.max);
        for (final x in xs) {
          vLine(px(x).round(), px(minY - 3).round(), px(maxY + 3).round(), 160, dashed: true);
        }
        for (final y in ys) {
          hLine(px(y).round(), px(minX - 3).round(), px(maxX + 3).round(), 160, dashed: true);
        }
      }
      if (marks) {
        final len = px(math.max(1.0, math.min(3.0, gap / 2 + 1.5))).round();
        for (final c in cells) {
          final l = px(c[0]).round(), t = px(c[1]).round(), r = px(c[0] + c[2]).round(), b = px(c[1] + c[3]).round();
          hLine(t, l - len, l - 2, 0);
          vLine(l, t - len, t - 2, 0);
          hLine(t, r + 2, r + len, 0);
          vLine(r, t - len, t - 2, 0);
          hLine(b, l - len, l - 2, 0);
          vLine(l, b + 2, b + len, 0);
          hLine(b, r + 2, r + len, 0);
          vLine(r, b + 2, b + len, 0);
        }
      }
      final image = rgbToImage(sheet);
      return png ? withPngDpi(img.encodePng(image), dpi) : withJpegDpi(img.encodeJpg(image, quality: 95), dpi);
    });
  }

  /// One-page calibration chart: printed at 100 % the lines measure exactly
  /// 100 mm and the squares 50 mm / 1 inch.
  static Uint8List calibrationPdf(PaperSize paper) {
    final doc = sf.PdfDocument();
    try {
      doc.pageSettings.margins.all = 0;
      doc.documentInformation.title = 'ScanPro print calibration';
      final section = doc.sections!.add();
      section.pageSettings.margins.all = 0;
      section.pageSettings.size = Size(pt(paper.widthMm), pt(paper.heightMm));
      final page = section.pages.add();
      final g = page.graphics;
      final title = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 14, style: sf.PdfFontStyle.bold);
      final body = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 9);
      final small = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 6);
      final black = sf.PdfBrushes.black;
      final pen = sf.PdfPen(sf.PdfColor(0, 0, 0), width: 0.4);
      final thin = sf.PdfPen(sf.PdfColor(0, 0, 0), width: 0.2);
      const left = 15.0;
      g.drawString('Print calibration – ${paper.name}', title, brush: black, bounds: Rect.fromLTWH(pt(left), pt(12), pt(170), pt(8)));
      g.drawString(
        'Print this page with scaling set to 100% / "Actual size" (turn OFF "Fit to page" / "Shrink to fit").\n'
        'Then measure with a ruler: the horizontal and vertical lines must be exactly 100 mm, the square 50 mm and the small square 1 inch (25.4 mm).\n'
        'If they differ, your printer driver is scaling the output. Printer hardware margins can also clip edges.',
        body,
        brush: black,
        bounds: Rect.fromLTWH(pt(left), pt(22), pt(paper.widthMm - 2 * left), pt(20)),
      );
      // Horizontal 100 mm ruler.
      const hy = 55.0;
      g.drawLine(pen, Offset(pt(left), pt(hy)), Offset(pt(left + 100), pt(hy)));
      for (var i = 0; i <= 100; i++) {
        final tick = i % 10 == 0 ? 4.0 : (i % 5 == 0 ? 2.5 : 1.5);
        g.drawLine(i % 10 == 0 ? pen : thin, Offset(pt(left + i), pt(hy)), Offset(pt(left + i), pt(hy + tick)));
        if (i % 10 == 0) {
          g.drawString('$i', small, brush: black, bounds: Rect.fromLTWH(pt(left + i - 2), pt(hy + 4.5), pt(6), pt(3)));
        }
      }
      g.drawString('100 mm', body, brush: black, bounds: Rect.fromLTWH(pt(left + 103), pt(hy - 2), pt(30), pt(5)));
      // Vertical 100 mm ruler.
      const vx = 15.0, vy = 70.0;
      g.drawLine(pen, Offset(pt(vx), pt(vy)), Offset(pt(vx), pt(vy + 100)));
      for (var i = 0; i <= 100; i++) {
        final tick = i % 10 == 0 ? 4.0 : (i % 5 == 0 ? 2.5 : 1.5);
        g.drawLine(i % 10 == 0 ? pen : thin, Offset(pt(vx), pt(vy + i)), Offset(pt(vx + tick), pt(vy + i)));
        if (i % 10 == 0) {
          g.drawString('$i', small, brush: black, bounds: Rect.fromLTWH(pt(vx + 5), pt(vy + i - 1.2), pt(6), pt(3)));
        }
      }
      // 50 mm square and 1 inch square.
      g.drawRectangle(pen: pen, bounds: Rect.fromLTWH(pt(45), pt(80), pt(50), pt(50)));
      g.drawString('50 × 50 mm', body, brush: black, bounds: Rect.fromLTWH(pt(45), pt(132), pt(40), pt(5)));
      g.drawRectangle(pen: pen, bounds: Rect.fromLTWH(pt(110), pt(80), pt(25.4), pt(25.4)));
      g.drawString('1 × 1 inch', body, brush: black, bounds: Rect.fromLTWH(pt(110), pt(107), pt(40), pt(5)));
      // Passport-size reference outlines.
      g.drawRectangle(pen: thin, bounds: Rect.fromLTWH(pt(110), pt(120), pt(35), pt(45)));
      g.drawString('35 × 45 mm', small, brush: black, bounds: Rect.fromLTWH(pt(110), pt(166), pt(30), pt(3)));
      g.drawRectangle(pen: thin, bounds: Rect.fromLTWH(pt(150), pt(120), pt(50.8), pt(50.8)));
      g.drawString('2 × 2 in (50.8 mm)', small, brush: black, bounds: Rect.fromLTWH(pt(150), pt(172), pt(40), pt(3)));
      // Edge markers 5 mm from each paper edge to reveal hardware margins.
      final w = paper.widthMm, h = paper.heightMm;
      for (final (x, y) in [(5.0, 5.0), (w - 5, 5.0), (5.0, h - 5), (w - 5, h - 5)]) {
        g.drawLine(thin, Offset(pt(x - 3), pt(y)), Offset(pt(x + 3), pt(y)));
        g.drawLine(thin, Offset(pt(x), pt(y - 3)), Offset(pt(x), pt(y + 3)));
      }
      g.drawString('Crosses are 5 mm from the paper edges. Missing crosses = printer cannot print that close to the edge.', small,
          brush: black, bounds: Rect.fromLTWH(pt(left), pt(h - 14), pt(w - 2 * left), pt(4)));
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// DPI metadata helpers (pure functions; unit tested)
// ---------------------------------------------------------------------------

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Inserts/replaces a pHYs chunk so the PNG declares [dpi].
Uint8List withPngDpi(Uint8List png, int dpi) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  if (png.length < 33) return png;
  for (var i = 0; i < 8; i++) {
    if (png[i] != sig[i]) return png;
  }
  final ppm = (dpi / 0.0254).round();
  final out = BytesBuilder();
  out.add(png.sublist(0, 8));
  var pos = 8;
  var inserted = false;
  while (pos + 8 <= png.length) {
    final len = (png[pos] << 24) | (png[pos + 1] << 16) | (png[pos + 2] << 8) | png[pos + 3];
    final type = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
    final end = pos + 12 + len;
    if (end > png.length) break;
    if (type == 'pHYs') {
      pos = end;
      continue; // drop existing; ours is inserted after IHDR
    }
    out.add(png.sublist(pos, end));
    if (type == 'IHDR' && !inserted) {
      final chunk = Uint8List(21);
      final cd = ByteData.sublistView(chunk);
      cd.setUint32(0, 9);
      chunk.setAll(4, 'pHYs'.codeUnits);
      cd.setUint32(8, ppm);
      cd.setUint32(12, ppm);
      chunk[16] = 1; // metre
      cd.setUint32(17, crc32(chunk.sublist(4, 17)));
      out.add(chunk);
      inserted = true;
    }
    pos = end;
  }
  return out.toBytes();
}

/// Sets the JFIF density of a JPEG to [dpi] (inserting APP0 if missing).
Uint8List withJpegDpi(Uint8List jpg, int dpi) {
  if (jpg.length < 4 || jpg[0] != 0xFF || jpg[1] != 0xD8) return jpg;
  final out = Uint8List.fromList(jpg);
  if (jpg[2] == 0xFF && jpg[3] == 0xE0 && jpg.length > 18 && String.fromCharCodes(jpg.sublist(6, 10)) == 'JFIF') {
    out[13] = 1; // units: dots per inch
    out[14] = (dpi >> 8) & 0xFF;
    out[15] = dpi & 0xFF;
    out[16] = (dpi >> 8) & 0xFF;
    out[17] = dpi & 0xFF;
    return out;
  }
  final app0 = <int>[
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, //
    (dpi >> 8) & 0xFF, dpi & 0xFF, (dpi >> 8) & 0xFF, dpi & 0xFF, 0x00, 0x00,
  ];
  return Uint8List.fromList([0xFF, 0xD8, ...app0, ...jpg.sublist(2)]);
}

/// Reads the DPI declared in a PNG pHYs chunk (for tests/verification).
int? readPngDpi(Uint8List png) {
  var pos = 8;
  while (pos + 8 <= png.length) {
    final len = (png[pos] << 24) | (png[pos + 1] << 16) | (png[pos + 2] << 8) | png[pos + 3];
    final type = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
    if (type == 'pHYs' && pos + 8 + 9 <= png.length) {
      final ppm = (png[pos + 8] << 24) | (png[pos + 9] << 16) | (png[pos + 10] << 8) | png[pos + 11];
      return (ppm * 0.0254).round();
    }
    pos += 12 + len;
  }
  return null;
}

bool fileOk(String path) => File(path).existsSync();
