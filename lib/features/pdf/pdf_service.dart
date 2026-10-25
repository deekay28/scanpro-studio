import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../core/models.dart';
import '../../core/ocr_models.dart';
import '../../core/storage.dart';
import '../../core/units.dart';
import '../../imaging/processor.dart';

enum FitMode { fit, fill, original }

extension FitModeLabel on FitMode {
  String get label => switch (this) {
        FitMode.fit => 'Fit to page',
        FitMode.fill => 'Fill page',
        FitMode.original => 'Original size',
      };
}

/// Options for building a PDF from scanned pages.
class PdfExportOptions {
  final PaperSize? pageSize; // null = match each image
  final bool landscape;
  final bool autoOrientation;
  final FitMode fit;
  final double marginMm;
  final bool pageNumbers;
  final bool searchable;
  final String? password;
  final String title;
  final String? author;
  final String? subject;
  final String? keywords;
  final int maxDim;
  final int quality;
  final bool grayscale;
  final String? watermark;
  final Color background;

  const PdfExportOptions({
    this.pageSize = PaperSizes.a4,
    this.landscape = false,
    this.autoOrientation = true,
    this.fit = FitMode.fit,
    this.marginMm = 0,
    this.pageNumbers = false,
    this.searchable = false,
    this.password,
    this.title = 'Document',
    this.author,
    this.subject,
    this.keywords,
    this.maxDim = 2400,
    this.quality = 85,
    this.grayscale = false,
    this.watermark,
    this.background = const Color(0xFFFFFFFF),
  });
}

/// Compression presets (image resolution + JPEG quality).
class CompressionPreset {
  final String id;
  final String label;
  final String hint;
  final int maxDim;
  final int quality;
  final double rasterDpi;
  const CompressionPreset(this.id, this.label, this.hint, this.maxDim, this.quality, this.rasterDpi);

  static const printQuality = CompressionPreset('print', 'Print quality', 'High resolution, larger file', 3300, 90, 220);
  static const standard = CompressionPreset('standard', 'Standard', 'Balanced quality and size', 2400, 82, 160);
  static const email = CompressionPreset('email', 'Email', 'Small, readable', 1700, 70, 120);
  static const messaging = CompressionPreset('messaging', 'Messaging', 'Smallest file', 1200, 60, 96);
  static const all = [printQuality, standard, email, messaging];
}

/// Reference to a page used when rebuilding PDFs.
class PdfPageRef {
  final int source; // index into the sources list
  final int index; // page index in that source; -1 for a blank page
  final int rotation; // extra clockwise rotation
  const PdfPageRef(this.source, this.index, {this.rotation = 0});
  bool get blank => index < 0;
  PdfPageRef rotated(int d) => PdfPageRef(source, index, rotation: (rotation + d + 360) % 360);
}

class PdfSource {
  final Uint8List bytes;
  final String? password;
  const PdfSource(this.bytes, {this.password});
}

class PdfInfo {
  final int pageCount;
  final List<Size> pageSizes; // points
  final bool encrypted;
  final String? title;
  const PdfInfo(this.pageCount, this.pageSizes, this.encrypted, this.title);
}

class PdfPasswordRequired implements Exception {
  @override
  String toString() => 'This PDF is password protected.';
}

class PdfService {
  static Uint8List? _fontCache;

  static Future<Uint8List> _fontBytes() async {
    final c = _fontCache;
    if (c != null) return c;
    final data = await rootBundle.load('assets/fonts/FreeSans.ttf');
    return _fontCache = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static sf.PdfPageRotateAngle _angle(int deg) => switch (((deg % 360) + 360) % 360) {
        90 => sf.PdfPageRotateAngle.rotateAngle90,
        180 => sf.PdfPageRotateAngle.rotateAngle180,
        270 => sf.PdfPageRotateAngle.rotateAngle270,
        _ => sf.PdfPageRotateAngle.rotateAngle0,
      };

  static int _deg(sf.PdfPageRotateAngle a) => switch (a) {
        sf.PdfPageRotateAngle.rotateAngle90 => 90,
        sf.PdfPageRotateAngle.rotateAngle180 => 180,
        sf.PdfPageRotateAngle.rotateAngle270 => 270,
        _ => 0,
      };

  static void _applyInfo(sf.PdfDocument doc, {String? title, String? author, String? subject, String? keywords}) {
    final info = doc.documentInformation;
    if (title != null) info.title = title;
    if (author != null && author.isNotEmpty) info.author = author;
    if (subject != null && subject.isNotEmpty) info.subject = subject;
    if (keywords != null && keywords.isNotEmpty) info.keywords = keywords;
    info.creator = 'ScanPro Studio';
  }

  static void _protect(sf.PdfDocument doc, String? password) {
    if (password == null || password.isEmpty) return;
    final s = doc.security;
    s.algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit;
    s.userPassword = password;
    s.ownerPassword = password;
  }

  /// Draws [text] invisibly, stretched to [bounds], so viewers can search
  /// and select it on top of the page image.
  static void _drawHiddenText(sf.PdfGraphics g, sf.PdfFont font, String text, Rect bounds) {
    final t = text.trim();
    if (t.isEmpty || bounds.width <= 0 || bounds.height <= 0) return;
    final size = font.measureString(t);
    if (size.width <= 0 || size.height <= 0) return;
    g.save();
    g.setTransparency(0);
    g.translateTransform(bounds.left, bounds.top);
    g.scaleTransform(bounds.width / size.width, bounds.height / size.height);
    g.drawString(t, font, brush: sf.PdfBrushes.black, bounds: Rect.fromLTWH(0, 0, size.width, size.height));
    g.restore();
  }

  static void _drawWatermark(sf.PdfGraphics g, String text, double pw, double ph) {
    final font = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, math.min(pw, ph) / 9, style: sf.PdfFontStyle.bold);
    final s = font.measureString(text);
    g.save();
    g.setTransparency(0.16);
    g.translateTransform(pw / 2, ph / 2);
    g.rotateTransform(-45);
    g.drawString(text, font,
        brush: sf.PdfSolidBrush(sf.PdfColor(180, 20, 20)), bounds: Rect.fromLTWH(-s.width / 2, -s.height / 2, s.width, s.height));
    g.restore();
  }

  static void _drawPageNumber(sf.PdfGraphics g, int index, int total, double pw, double ph) {
    final font = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 9);
    final label = '${index + 1} / $total';
    final s = font.measureString(label);
    g.drawString(label, font,
        brush: sf.PdfSolidBrush(sf.PdfColor(90, 90, 90)), bounds: Rect.fromLTWH((pw - s.width) / 2, ph - mmToPt(6) - s.height, s.width, s.height));
  }

  /// Computes where an image of [iw]x[ih] px goes inside [box] (points).
  static Rect placeImage(Rect box, int iw, int ih, FitMode fit, {double assumedDpi = 200}) {
    double scale = 1;
    switch (fit) {
      case FitMode.fit:
        scale = math.min(box.width / iw, box.height / ih);
      case FitMode.fill:
        scale = math.max(box.width / iw, box.height / ih);
      case FitMode.original:
        {
          scale = ptPerInch / assumedDpi;
          final fitScale = math.min(box.width / iw, box.height / ih);
          if (scale > fitScale) scale = fitScale;
        }
    }
    final w = iw * scale, h = ih * scale;
    return Rect.fromLTWH(box.left + (box.width - w) / 2, box.top + (box.height - h) / 2, w, h);
  }

  /// Page size in points for an image under the given options.
  static Size pageSizeFor(PdfExportOptions o, int iw, int ih) {
    final ps = o.pageSize;
    if (ps == null) {
      // Match the image aspect; short side = 210 mm.
      if (iw <= ih) {
        final w = mmToPt(210);
        return Size(w, w * ih / iw);
      }
      final h = mmToPt(210);
      return Size(h * iw / ih, h);
    }
    final land = o.autoOrientation ? iw > ih : o.landscape;
    final s = ps.oriented(land);
    return Size(mmToPt(s.widthMm), mmToPt(s.heightMm));
  }

  /// Builds a PDF from scanned pages. Pages are encoded one at a time to
  /// keep memory bounded. Returns the PDF bytes.
  static Future<Uint8List> buildFromPages(
    List<DocPage> pages,
    PdfExportOptions o, {
    Future<OcrPageResult?> Function(DocPage page)? ocrFor,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (pages.isEmpty) throw const FormatException('The document has no pages.');
    final doc = sf.PdfDocument();
    try {
      doc.pageSettings.margins.all = 0;
      _applyInfo(doc, title: o.title, author: o.author, subject: o.subject, keywords: o.keywords);
      sf.PdfFont? hidden;
      if (o.searchable) hidden = sf.PdfTrueTypeFont(await _fontBytes(), 10);
      final storage = AppStorage.instance;
      for (var i = 0; i < pages.length; i++) {
        if (isCancelled?.call() ?? false) throw const _Cancelled();
        final page = pages[i];
        final (jpg, iw, ih) = await preparePdfImage(
          storage.abs(page.displayPath),
          overlayPath: page.overlayPath == null ? null : storage.abs(page.overlayPath!),
          maxDim: o.maxDim,
          quality: o.quality,
          gray: o.grayscale,
        );
        final size = pageSizeFor(o, iw, ih);
        final section = doc.sections!.add();
        section.pageSettings.margins.all = 0;
        section.pageSettings.size = size;
        final pg = section.pages.add();
        final g = pg.graphics;
        final pw = size.width, ph = size.height;
        if (o.background.toARGB32() != 0xFFFFFFFF) {
          final c = o.background;
          g.drawRectangle(
            brush: sf.PdfSolidBrush(sf.PdfColor((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round())),
            bounds: Rect.fromLTWH(0, 0, pw, ph),
          );
        }
        final m = o.pageSize == null ? 0.0 : mmToPt(o.marginMm);
        final box = Rect.fromLTWH(m, m, pw - 2 * m, ph - 2 * m);
        final rect = placeImage(box, iw, ih, o.fit);
        final clip = o.fit == FitMode.fill;
        if (clip) {
          g.save();
          g.setClip(bounds: box);
        }
        g.drawImage(sf.PdfBitmap(jpg), rect);
        if (hidden != null && ocrFor != null) {
          final ocr = await ocrFor(page);
          if (ocr != null && ocr.imageWidth > 0 && ocr.imageHeight > 0) {
            final sx = rect.width / ocr.imageWidth, sy = rect.height / ocr.imageHeight;
            for (final l in ocr.lines) {
              _drawHiddenText(g, hidden, l.text,
                  Rect.fromLTWH(rect.left + l.left * sx, rect.top + l.top * sy, l.width * sx, l.height * sy));
            }
          }
        }
        if (clip) g.restore();
        if (o.watermark != null && o.watermark!.trim().isNotEmpty) _drawWatermark(g, o.watermark!.trim(), pw, ph);
        if (o.pageNumbers) _drawPageNumber(g, i, pages.length, pw, ph);
        onProgress?.call(i + 1, pages.length);
      }
      _protect(doc, o.password);
      final bytes = await doc.save();
      return Uint8List.fromList(bytes);
    } finally {
      doc.dispose();
    }
  }

  // -------------------------------------------------------------------------
  // Existing PDFs
  // -------------------------------------------------------------------------

  static sf.PdfDocument _open(PdfSource s) {
    try {
      return s.password == null || s.password!.isEmpty
          ? sf.PdfDocument(inputBytes: s.bytes)
          : sf.PdfDocument(inputBytes: s.bytes, password: s.password);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('password') || msg.contains('encrypt')) throw PdfPasswordRequired();
      throw FormatException('This PDF is damaged or not supported. ($e)');
    }
  }

  static PdfInfo inspect(PdfSource s) {
    final doc = _open(s);
    try {
      final sizes = <Size>[for (var i = 0; i < doc.pages.count; i++) doc.pages[i].size];
      return PdfInfo(doc.pages.count, sizes, s.password != null && s.password!.isNotEmpty, doc.documentInformation.title);
    } finally {
      doc.dispose();
    }
  }

  static bool isEncrypted(Uint8List bytes) {
    try {
      sf.PdfDocument(inputBytes: bytes).dispose();
      return false;
    } catch (e) {
      final msg = e.toString().toLowerCase();
      return msg.contains('password') || msg.contains('encrypt');
    }
  }

  /// Extracts the text layer of each page (empty strings for image-only pages).
  static List<String> extractText(PdfSource s) {
    final doc = _open(s);
    try {
      final ex = sf.PdfTextExtractor(doc);
      return [
        for (var i = 0; i < doc.pages.count; i++)
          () {
            try {
              return ex.extractText(startPageIndex: i, endPageIndex: i);
            } catch (_) {
              return '';
            }
          }()
      ];
    } finally {
      doc.dispose();
    }
  }

  /// Builds a new PDF from page references into one or more sources.
  /// Page content is copied as vector templates, so existing text stays
  /// searchable and nothing is rasterised. Links, form fields and
  /// annotations of the source pages are not carried over.
  static Uint8List rebuild(
    List<PdfSource> sources,
    List<PdfPageRef> refs, {
    String? newPassword,
    bool maxCompression = false,
    String? title,
    Size blankSize = const Size(595.28, 841.89),
  }) {
    if (refs.isEmpty) throw const FormatException('No pages selected.');
    final opened = <int, sf.PdfDocument>{};
    final out = sf.PdfDocument();
    try {
      out.pageSettings.margins.all = 0;
      if (maxCompression) out.compressionLevel = sf.PdfCompressionLevel.best;
      _applyInfo(out, title: title);
      for (final r in refs) {
        final section = out.sections!.add();
        section.pageSettings.margins.all = 0;
        if (r.blank) {
          section.pageSettings.size = blankSize;
          final np = section.pages.add();
          if (r.rotation != 0) np.rotation = _angle(r.rotation);
          continue;
        }
        final src = opened.putIfAbsent(r.source, () => _open(sources[r.source]));
        if (r.index >= src.pages.count) throw RangeError('Page ${r.index + 1} does not exist');
        final sp = src.pages[r.index];
        final size = sp.size;
        section.pageSettings.size = size;
        final np = section.pages.add();
        np.graphics.drawPdfTemplate(sp.createTemplate(), Offset.zero, size);
        final total = _deg(sp.rotation) + r.rotation;
        if (total % 360 != 0) np.rotation = _angle(total);
      }
      _protect(out, newPassword);
      return Uint8List.fromList(out.saveSync());
    } finally {
      out.dispose();
      for (final d in opened.values) {
        d.dispose();
      }
    }
  }

  /// Parses "1-3, 5, 8-" style ranges (1-based) into 0-based groups.
  static List<List<int>> parseRanges(String input, int pageCount) {
    final groups = <List<int>>[];
    for (final part in input.split(RegExp(r'[,;]'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final m = RegExp(r'^(\d*)\s*-\s*(\d*)$').firstMatch(t);
      int a, b;
      if (m != null) {
        a = m.group(1)!.isEmpty ? 1 : int.parse(m.group(1)!);
        b = m.group(2)!.isEmpty ? pageCount : int.parse(m.group(2)!);
      } else {
        final n = int.tryParse(t);
        if (n == null) throw FormatException('Invalid range "$t"');
        a = n;
        b = n;
      }
      if (a < 1 || b > pageCount || a > b) throw FormatException('Range "$t" is outside 1-$pageCount');
      groups.add([for (var i = a; i <= b; i++) i - 1]);
    }
    if (groups.isEmpty) throw const FormatException('Enter at least one page range');
    return groups;
  }

  /// Strong compression: renders every page to a JPEG at [dpi]. The text
  /// layer is re-added invisibly from the source so the result stays
  /// searchable, but vector graphics become images.
  static Future<Uint8List> rasterCompress(
    PdfSource source,
    CompressionPreset preset, {
    String? newPassword,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool keepText = true,
  }) async {
    // Decrypt first; the platform renderer cannot open encrypted files.
    final info = inspect(source);
    final plain = source.password != null && source.password!.isNotEmpty
        ? rebuild([source], [for (var i = 0; i < info.pageCount; i++) PdfPageRef(0, i)])
        : source.bytes;
    final textDoc = keepText ? sf.PdfDocument(inputBytes: plain) : null;
    final ex = textDoc == null ? null : sf.PdfTextExtractor(textDoc);
    final out = sf.PdfDocument();
    try {
      out.pageSettings.margins.all = 0;
      _applyInfo(out, title: info.title);
      final font = keepText ? sf.PdfTrueTypeFont(await _fontBytes(), 10) : null;
      var i = 0;
      await for (final raster in Printing.raster(plain, dpi: preset.rasterDpi)) {
        if (isCancelled?.call() ?? false) throw const _Cancelled();
        final w = raster.width, h = raster.height;
        final jpg = await _rgbaToJpeg(raster.pixels, w, h, preset.quality);
        final size = i < info.pageSizes.length ? info.pageSizes[i] : Size(w * 72 / preset.rasterDpi, h * 72 / preset.rasterDpi);
        // Raster output is already rotated for display; use displayed size.
        final disp = (w > h) == (size.width > size.height) ? size : Size(size.height, size.width);
        final section = out.sections!.add();
        section.pageSettings.margins.all = 0;
        section.pageSettings.size = disp;
        final pg = section.pages.add();
        pg.graphics.drawImage(sf.PdfBitmap(jpg), Rect.fromLTWH(0, 0, disp.width, disp.height));
        if (font != null && ex != null && textDoc != null) {
          try {
            final rot = _deg(textDoc.pages[i].rotation);
            if (rot == 0) {
              for (final line in ex.extractTextLines(startPageIndex: i, endPageIndex: i)) {
                _drawHiddenText(pg.graphics, font, line.text, line.bounds);
              }
            }
          } catch (_) {}
        }
        i++;
        onProgress?.call(i, info.pageCount);
      }
      _protect(out, newPassword);
      return Uint8List.fromList(await out.save());
    } finally {
      out.dispose();
      textDoc?.dispose();
    }
  }

  static Future<Uint8List> _rgbaToJpeg(Uint8List rgba, int w, int h, int quality) => Isolate.run(() {
        final im = img.Image.fromBytes(width: w, height: h, bytes: Uint8List.fromList(rgba).buffer, numChannels: 4, order: img.ChannelOrder.rgba);
        final rgb = imageToRgb(im);
        return encodeJpeg(rgb, quality);
      });

  /// Renders small page thumbnails (PNG bytes) for page pickers.
  static Stream<Uint8List> thumbnails(Uint8List bytes, {double dpi = 36, List<int>? pages}) async* {
    await for (final r in Printing.raster(bytes, dpi: dpi, pages: pages)) {
      yield await r.toPng();
    }
  }

  /// Renders pages as PNG images at [dpi] (for "PDF to images").
  static Stream<(int, Uint8List)> renderPages(Uint8List bytes, {double dpi = 150, List<int>? pages}) async* {
    var i = 0;
    await for (final r in Printing.raster(bytes, dpi: dpi, pages: pages)) {
      yield (pages == null ? i : pages[i], await r.toPng());
      i++;
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => 'Cancelled';
}
