import 'dart:convert' show latin1;
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfium_dart/pdfium_dart.dart';

import '../../convert/model/page_content.dart';
import '../model/edit_state.dart';
import 'pdf_edit_engine.dart';
import 'text_layout.dart';

part 'pdfium_security.dart';
part 'pdfium_tools.dart';

/// PDFium-based implementation of [PdfEditEngine] (BSD-3/Apache-2.0,
/// runs fully on-device). PDFium edits real page content: text objects can
/// be rewritten in their own font, removed or added, images replaced, and
/// annotations created. It is not thread-safe, so every call happens on the
/// isolate that created the engine.
class PdfiumEngine implements PdfEditEngine {
  /// Unicode TrueType font used when a standard font lacks glyphs.
  final Uint8List unicodeFont;

  PdfiumEngine({required this.unicodeFont});

  /// Explicit library path (tests run on the host with a downloaded build).
  static String? modulePath;

  static PDFium? _lib;
  static PDFium get lib {
    final l = _lib;
    if (l != null) return l;
    final n = getPdfium(modulePath: modulePath);
    n.FPDF_InitLibrary();
    return _lib = n;
  }

  @override
  PdfEditSession open(Uint8List bytes, {String? password}) => PdfiumSession._open(this, bytes, password);
}

// ---------------------------------------------------------------------------
// Geometry: PDF user space <-> display points (top-left origin, rotation
// applied).
// ---------------------------------------------------------------------------

class _Geom {
  final double l, b, r, t; // crop box
  final int rot; // quarter turns clockwise
  _Geom(this.l, this.b, this.r, this.t, this.rot);

  double get w0 => r - l;
  double get h0 => t - b;
  Size get display => rot.isOdd ? Size(h0, w0) : Size(w0, h0);

  Offset toDisplay(double x, double y) {
    final xp = x - l, yp = t - y;
    return switch (rot) {
      1 => Offset(h0 - yp, xp),
      2 => Offset(w0 - xp, h0 - yp),
      3 => Offset(yp, w0 - xp),
      _ => Offset(xp, yp),
    };
  }

  (double, double) toUser(Offset d) {
    final (xp, yp) = switch (rot) {
      1 => (d.dy, h0 - d.dx),
      2 => (w0 - d.dx, h0 - d.dy),
      3 => (w0 - d.dy, d.dx),
      _ => (d.dx, d.dy),
    };
    return (xp + l, t - yp);
  }

  Rect rectToDisplay(double left, double bottom, double right, double top) {
    final a = toDisplay(left, bottom), c = toDisplay(right, top);
    return Rect.fromPoints(a, c);
  }

  /// User-space rectangle (left, bottom, right, top) of a display rect.
  (double, double, double, double) rectToUser(Rect d) {
    final (x1, y1) = toUser(d.topLeft);
    final (x2, y2) = toUser(d.bottomRight);
    return (math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2));
  }

  /// Matrix mapping a local frame (origin, x axis, y axis given in display
  /// points; y axis pointing visually up) to user space.
  List<double> frame(Offset origin, Offset xAxis, Offset yAxis) {
    final (ox, oy) = toUser(origin);
    final (xx, xy) = toUser(origin + xAxis);
    final (yx, yy) = toUser(origin + yAxis);
    return [xx - ox, xy - oy, yx - ox, yy - oy, ox, oy];
  }
}

Offset _rotate(Offset v, double deg) {
  if (deg == 0) return v;
  final a = deg * math.pi / 180;
  final c = math.cos(a), s = math.sin(a);
  // Clockwise in display coordinates (y down).
  return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

const _winAnsiExtra = '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ';

bool _isWinAnsi(String s) {
  for (final r in s.runes) {
    if (r < 0x20 && r != 0x09 && r != 0x0a && r != 0x0d) return false;
    if (r <= 0x7e || (r >= 0xa0 && r <= 0xff)) continue;
    if (!_winAnsiExtra.runes.contains(r)) return false;
  }
  return true;
}

bool _hasDevanagari(String s) => s.runes.any((r) => r >= 0x0900 && r <= 0x097F);

class _Font {
  final Pointer<fpdf_font_t__> handle;
  final String name;
  final bool owned; // must be closed with FPDFFont_Close
  final bool original;
  const _Font(this.handle, this.name, {this.owned = true, this.original = false});
}

/// Per-document resources used while applying edits.
class _ApplyCtx {
  final FPDF_DOCUMENT doc;
  final String draftDir;
  final Map<String, _Font> fonts = {};
  final List<String> warnings = [];
  _ApplyCtx(this.doc, this.draftDir);
}

class PdfiumSession implements PdfEditSession {
  final PdfiumEngine engine;
  final Pointer<Uint8> _buf;
  final int _len;
  @override
  final String? password;
  final FPDF_DOCUMENT _ref; // read-only reference document
  @override
  final bool encrypted;
  final Map<int, PageAnalysis> _analysis = {};
  bool _closed = false;

  PdfiumSession._(this.engine, this._buf, this._len, this.password, this._ref, this.encrypted);

  static PDFium get _p => PdfiumEngine.lib;

  static PdfiumSession _open(PdfiumEngine engine, Uint8List bytes, String? password) {
    final p = _p;
    final buf = malloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final doc = _load(buf, bytes.length, password);
    if (doc == nullptr) {
      final err = p.FPDF_GetLastError();
      malloc.free(buf);
      if (err == 4) throw EditorPasswordRequired(wrong: password != null && password.isNotEmpty);
      throw const PdfEditException('This PDF is damaged or uses features that cannot be edited.');
    }
    final isEnc = p.FPDF_GetSecurityHandlerRevision(doc) != -1;
    if (isEnc) {
      final perms = p.FPDF_GetDocPermissions(doc);
      // Bit 4 (value 8): modify contents. Owner password grants everything.
      if (perms & 8 == 0) {
        p.FPDF_CloseDocument(doc);
        malloc.free(buf);
        throw EditorPermissionDenied();
      }
    }
    return PdfiumSession._(engine, buf, bytes.length, password, doc, isEnc);
  }

  static FPDF_DOCUMENT _load(Pointer<Uint8> buf, int len, String? password) {
    final pw = password == null || password.isEmpty ? nullptr : password.toNativeUtf8();
    try {
      return _p.FPDF_LoadMemDocument64(buf.cast(), len, pw.cast());
    } finally {
      if (pw != nullptr) malloc.free(pw);
    }
  }

  FPDF_DOCUMENT _loadCopy() {
    final d = _load(_buf, _len, password);
    if (d == nullptr) throw const PdfEditException('Could not re-open the document.');
    return d;
  }

  @override
  int get pageCount => _p.FPDF_GetPageCount(_ref);

  @override
  String? get title {
    final p = _p;
    final key = 'Title'.toNativeUtf8();
    try {
      final n = p.FPDF_GetMetaText(_ref, key.cast(), nullptr, 0);
      if (n <= 2) return null;
      final b = malloc<Uint16>(n ~/ 2);
      try {
        p.FPDF_GetMetaText(_ref, key.cast(), b.cast(), n);
        return String.fromCharCodes(b.asTypedList(n ~/ 2 - 1));
      } finally {
        malloc.free(b);
      }
    } finally {
      malloc.free(key);
    }
  }

  static _Geom _geom(FPDF_PAGE page) {
    final p = _p;
    return using((a) {
      final l = a<Float>(), b = a<Float>(), r = a<Float>(), t = a<Float>();
      var ok = p.FPDFPage_GetCropBox(page, l, b, r, t) != 0;
      if (!ok) ok = p.FPDFPage_GetMediaBox(page, l, b, r, t) != 0;
      double L, B, R, T;
      if (ok) {
        L = math.min(l.value, r.value);
        R = math.max(l.value, r.value);
        B = math.min(b.value, t.value);
        T = math.max(b.value, t.value);
      } else {
        L = 0;
        B = 0;
        R = p.FPDF_GetPageWidthF(page);
        T = p.FPDF_GetPageHeightF(page);
      }
      return _Geom(L, B, R, T, p.FPDFPage_GetRotation(page) % 4);
    });
  }

  FPDF_PAGE _loadPage(FPDF_DOCUMENT doc, int index) {
    final page = _p.FPDF_LoadPage(doc, index);
    if (page == nullptr) throw PdfEditException('Page ${index + 1} could not be loaded.');
    return page;
  }

  @override
  Size pageSize(int page) {
    final pg = _loadPage(_ref, page);
    try {
      return _geom(pg).display;
    } finally {
      _p.FPDF_ClosePage(pg);
    }
  }

  @override
  int pageRotation(int page) {
    final pg = _loadPage(_ref, page);
    try {
      return (_p.FPDFPage_GetRotation(pg) % 4) * 90;
    } finally {
      _p.FPDF_ClosePage(pg);
    }
  }

  @override
  Size slotSize(EditState state, String slotId) {
    final s = state.slot(slotId);
    if (s == null) return const Size(595, 842);
    return s.isBlank ? s.blankSize : pageSize(s.source!);
  }

  // -------------------------------------------------------------------------
  // Reading text runs and fonts
  // -------------------------------------------------------------------------

  static String _objText(FPDF_PAGEOBJECT o, FPDF_TEXTPAGE tp) {
    final p = _p;
    final n = p.FPDFTextObj_GetText(o, tp, nullptr, 0);
    if (n <= 2) return '';
    final b = malloc<Uint16>(n ~/ 2);
    try {
      p.FPDFTextObj_GetText(o, tp, b.cast(), n);
      return String.fromCharCodes(b.asTypedList(n ~/ 2 - 1));
    } finally {
      malloc.free(b);
    }
  }

  static List<double> _matrix(FPDF_PAGEOBJECT o) => using((a) {
        final m = a<FS_MATRIX>();
        if (_p.FPDFPageObj_GetMatrix(o, m) == 0) return [1, 0, 0, 1, 0, 0];
        final r = m.ref;
        return [r.a, r.b, r.c, r.d, r.e, r.f];
      });

  static void _setMatrix(FPDF_PAGEOBJECT o, List<double> v) => using((a) {
        final m = a<FS_MATRIX>();
        m.ref
          ..a = v[0]
          ..b = v[1]
          ..c = v[2]
          ..d = v[3]
          ..e = v[4]
          ..f = v[5];
        _p.FPDFPageObj_SetMatrix(o, m);
      });

  static Rect _objBounds(FPDF_PAGEOBJECT o, _Geom g) => using((a) {
        final l = a<Float>(), b = a<Float>(), r = a<Float>(), t = a<Float>();
        if (_p.FPDFPageObj_GetBounds(o, l, b, r, t) == 0) return Rect.zero;
        return g.rectToDisplay(l.value, b.value, r.value, t.value);
      });

  static int _fillColor(FPDF_PAGEOBJECT o) => using((a) {
        final r = a<UnsignedInt>(), g = a<UnsignedInt>(), b = a<UnsignedInt>(), al = a<UnsignedInt>();
        if (_p.FPDFPageObj_GetFillColor(o, r, g, b, al) == 0) return 0xFF000000;
        return (al.value.clamp(0, 255) << 24) | (r.value.clamp(0, 255) << 16) | (g.value.clamp(0, 255) << 8) | b.value.clamp(0, 255);
      });

  static FontFacts _fontFacts(Pointer<fpdf_font_t__> f) {
    final p = _p;
    var base = '';
    if (f != nullptr) {
      final n = p.FPDFFont_GetBaseFontName(f, nullptr, 0);
      if (n > 1) {
        final b = malloc<Char>(n);
        try {
          p.FPDFFont_GetBaseFontName(f, b, n);
          base = b.cast<Utf8>().toDartString();
        } catch (_) {
        } finally {
          malloc.free(b);
        }
      }
    }
    final subset = RegExp(r'^[A-Z]{6}\+').hasMatch(base);
    var family = subset ? base.substring(7) : base;
    final lower = family.toLowerCase();
    final weight = f == nullptr ? 400 : p.FPDFFont_GetWeight(f);
    final flags = f == nullptr ? 0 : p.FPDFFont_GetFlags(f);
    final italicAngle = f == nullptr
        ? 0
        : using((a) {
            final v = a<Int>();
            return p.FPDFFont_GetItalicAngle(f, v) != 0 ? v.value : 0;
          });
    final bold = lower.contains('bold') || lower.contains('black') || lower.contains('heavy') || lower.contains('semibold') || weight >= 600 || (flags & (1 << 18)) != 0;
    final italic = lower.contains('italic') || lower.contains('oblique') || italicAngle != 0 || (flags & (1 << 6)) != 0;
    family = family.replaceAll(RegExp(r'[-,]?(Bold|Italic|Oblique|BoldItalic|BoldOblique|Regular|Roman|MT|PS|PSMT)+$', caseSensitive: false), '');
    if (family.isEmpty) family = base.isEmpty ? 'Unknown font' : base;
    return FontFacts(
      baseName: base.isEmpty ? '(unnamed font)' : base,
      family: family,
      embedded: f != nullptr && p.FPDFFont_GetIsEmbedded(f) != 0,
      subset: subset,
      bold: bold,
      italic: italic,
      weight: weight,
    );
  }

  static double _fontSizeOf(FPDF_PAGEOBJECT o, List<double> m) {
    final s = using((a) {
      final v = a<Float>();
      return _p.FPDFTextObj_GetFontSize(o, v) != 0 ? v.value.toDouble() : 0.0;
    });
    // PDFium reports the Tf size; the text matrix may scale it.
    final scale = math.sqrt(m[2] * m[2] + m[3] * m[3]);
    return (s * (scale == 0 ? 1 : scale)).abs();
  }

  static bool _isUpright(List<double> m, _Geom g) {
    // The text x axis must point along the display +x direction.
    final o = g.toDisplay(m[4], m[5]);
    final x = g.toDisplay(m[4] + m[0], m[5] + m[1]) - o;
    final y = g.toDisplay(m[4] + m[2], m[5] + m[3]) - o;
    if (x.distance == 0 || y.distance == 0) return false;
    final xn = x / x.distance, yn = y / y.distance;
    return xn.dx > 0.999 && yn.dy < -0.999;
  }

  // -------------------------------------------------------------------------
  // Analysis
  // -------------------------------------------------------------------------

  @override
  PageAnalysis analyze(int page) => _analysis.putIfAbsent(page, () => _analyze(page));

  PageAnalysis _analyze(int pageIndex) {
    final p = _p;
    final page = _loadPage(_ref, pageIndex);
    final tp = p.FPDFText_LoadPage(page);
    try {
      final g = _geom(page);
      final size = g.display;
      final runs = <TextRunInfo>[];
      final images = <ImageObjInfo>[];
      var invisible = 0, forms = 0;
      var imageArea = 0.0;
      final n = p.FPDFPage_CountObjects(page);
      for (var i = 0; i < n; i++) {
        final o = p.FPDFPage_GetObject(page, i);
        final type = p.FPDFPageObj_GetType(o);
        if (type == FPDF_PAGEOBJ_TEXT) {
          final text = _objText(o, tp);
          if (text.trim().isEmpty) continue;
          final mode = p.FPDFTextObj_GetTextRenderMode(o);
          if (mode == FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_INVISIBLE) {
            invisible++;
            continue;
          }
          final m = _matrix(o);
          final font = p.FPDFTextObj_GetFont(o);
          runs.add(TextRunInfo(
            object: i,
            text: text,
            bounds: _objBounds(o, g),
            baseline: g.toDisplay(m[4], m[5]),
            size: _fontSizeOf(o, m),
            color: _fillColor(o),
            font: _fontFacts(font),
            upright: _isUpright(m, g),
            invisible: false,
          ));
        } else if (type == FPDF_PAGEOBJ_IMAGE) {
          final b = _objBounds(o, g);
          final (pw, ph) = using((a) {
            final w = a<UnsignedInt>(), h = a<UnsignedInt>();
            return p.FPDFImageObj_GetImagePixelSize(o, w, h) != 0 ? (w.value, h.value) : (0, 0);
          });
          images.add(ImageObjInfo(page: pageIndex, object: i, bounds: b, pixelWidth: pw, pixelHeight: ph));
          final clipped = b.intersect(Offset.zero & size);
          if (clipped.width > 0 && clipped.height > 0) imageArea += clipped.width * clipped.height;
        } else if (type == FPDF_PAGEOBJ_FORM) {
          forms++;
        }
      }
      final blocks = groupTextRuns(pageIndex, runs);
      return PageAnalysis(
        page: pageIndex,
        size: size,
        blocks: blocks,
        images: images,
        visibleTextRuns: runs.length,
        invisibleTextRuns: invisible,
        imageCoverage: size.isEmpty ? 0 : math.min(1, imageArea / (size.width * size.height)),
        formObjects: forms,
        annotations: p.FPDFPage_GetAnnotCount(page),
      );
    } finally {
      p.FPDFText_ClosePage(tp);
      p.FPDF_ClosePage(page);
    }
  }

  /// Groups runs into lines (same baseline) and lines into paragraph blocks
  /// (same font, size and colour, regular line spacing, overlapping
  /// horizontally). Rotated runs stay single-run blocks.
  static List<TextBlockInfo> groupTextRuns(int page, List<TextRunInfo> runs) {
    final upright = runs.where((r) => r.upright && r.size > 0).toList()
      ..sort((a, b) => a.baseline.dy != b.baseline.dy ? a.baseline.dy.compareTo(b.baseline.dy) : a.bounds.left.compareTo(b.bounds.left));
    // Lines.
    final lines = <List<TextRunInfo>>[];
    for (final r in upright) {
      List<TextRunInfo>? target;
      for (final l in lines.reversed) {
        final ref = l.first;
        if ((ref.baseline.dy - r.baseline.dy).abs() > 0.35 * math.max(ref.size, r.size)) {
          if (ref.baseline.dy < r.baseline.dy - 2 * r.size) break;
          continue;
        }
        if ((ref.size - r.size).abs() > 0.2 * ref.size) continue;
        final right = l.map((e) => e.bounds.right).reduce(math.max);
        final left = l.map((e) => e.bounds.left).reduce(math.min);
        final gap = r.bounds.left - right;
        if (gap > 3 * r.size || r.bounds.right < left - 3 * r.size) continue;
        target = l;
        break;
      }
      if (target == null) {
        lines.add([r]);
      } else {
        target.add(r);
        target.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      }
    }
    lines.sort((a, b) => a.first.baseline.dy.compareTo(b.first.baseline.dy));
    // Blocks.
    final groups = <List<List<TextRunInfo>>>[];
    for (final l in lines) {
      final f = l.first;
      final lRect = l.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
      List<List<TextRunInfo>>? target;
      for (final gr in groups.reversed) {
        final last = gr.last;
        final lf = last.first;
        final gap = f.baseline.dy - lf.baseline.dy;
        if (gap <= 0) continue;
        if (gap > 2.0 * lf.size) continue;
        if (gap < 0.8 * lf.size) continue;
        if ((lf.size - f.size).abs() > 0.1 * lf.size) continue;
        if (lf.font.family != f.font.family || lf.font.bold != f.font.bold || lf.font.italic != f.font.italic) continue;
        if (lf.color != f.color) continue;
        final gRect = last.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
        if (lRect.right < gRect.left || lRect.left > gRect.right) continue;
        // Keep the leading consistent within a block.
        if (gr.length >= 2) {
          final prevGap = lf.baseline.dy - gr[gr.length - 2].first.baseline.dy;
          if ((gap - prevGap).abs() > 0.25 * lf.size) continue;
        }
        target = gr;
        break;
      }
      if (target == null) {
        groups.add([l]);
      } else {
        target.add(l);
      }
    }
    final blocks = <TextBlockInfo>[];
    for (final gr in groups) {
      final all = [for (final l in gr) ...l];
      final rect = all.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
      final gaps = <double>[for (var i = 1; i < gr.length; i++) gr[i].first.baseline.dy - gr[i - 1].first.baseline.dy]..sort();
      final size = gr.first.first.size;
      final leading = gaps.isEmpty ? size * 1.2 : gaps[gaps.length ~/ 2];
      blocks.add(TextBlockInfo(page: page, runs: all, lines: gr, bounds: rect, leading: leading, align: _detectAlign(gr, size)));
    }
    for (final r in runs.where((r) => !r.upright || r.size <= 0)) {
      blocks.add(TextBlockInfo(page: page, runs: [r], lines: [[r]], bounds: r.bounds, leading: r.size * 1.2, align: TextAlign2.left));
    }
    return blocks;
  }

  static TextAlign2 _detectAlign(List<List<TextRunInfo>> lines, double size) {
    if (lines.length < 2) return TextAlign2.left;
    final lefts = [for (final l in lines) l.map((e) => e.bounds.left).reduce(math.min)];
    final rights = [for (final l in lines) l.map((e) => e.bounds.right).reduce(math.max)];
    bool same(List<double> v, int count) {
      final s = v.take(count).toList();
      return s.reduce(math.max) - s.reduce(math.min) < size * 0.5;
    }

    final leftSame = same(lefts, lefts.length);
    final rightSameButLast = same(rights, rights.length - 1);
    if (leftSame && rightSameButLast && lines.length >= 3) return TextAlign2.justify;
    if (leftSame) return TextAlign2.left;
    if (same(rights, rights.length)) return TextAlign2.right;
    final centers = [for (var i = 0; i < lines.length; i++) (lefts[i] + rights[i]) / 2];
    if (same(centers, centers.length)) return TextAlign2.center;
    return TextAlign2.left;
  }

  // -------------------------------------------------------------------------
  // Fonts for writing
  // -------------------------------------------------------------------------

  static String _standardName(FontChoice c, bool bold, bool italic) {
    switch (c) {
      case FontChoice.times:
        return bold && italic ? 'Times-BoldItalic' : (bold ? 'Times-Bold' : (italic ? 'Times-Italic' : 'Times-Roman'));
      case FontChoice.courier:
        return bold && italic ? 'Courier-BoldOblique' : (bold ? 'Courier-Bold' : (italic ? 'Courier-Oblique' : 'Courier'));
      default:
        return bold && italic ? 'Helvetica-BoldOblique' : (bold ? 'Helvetica-Bold' : (italic ? 'Helvetica-Oblique' : 'Helvetica'));
    }
  }

  /// Closest standard family for an original font name.
  static FontChoice familyFor(String fontName) {
    final n = fontName.toLowerCase();
    if (RegExp('times|serif|roman|georgia|garamond|cambria|book|minion|palatino|century|baskerville|caslon').hasMatch(n) && !n.contains('sans')) {
      return FontChoice.times;
    }
    if (RegExp('courier|mono|consol|code|typewriter').hasMatch(n)) return FontChoice.courier;
    return FontChoice.helvetica;
  }

  _Font _stdFont(_ApplyCtx ctx, FontChoice c, bool bold, bool italic) {
    if (c == FontChoice.unicodeSans) return _unicodeFont(ctx);
    final name = _standardName(c, bold, italic);
    return ctx.fonts.putIfAbsent(name, () {
      final n = name.toNativeUtf8();
      try {
        final f = _p.FPDFText_LoadStandardFont(ctx.doc, n.cast());
        if (f == nullptr) throw PdfEditException('Font $name unavailable');
        return _Font(f, name);
      } finally {
        malloc.free(n);
      }
    });
  }

  _Font _unicodeFont(_ApplyCtx ctx) => ctx.fonts.putIfAbsent('FreeSans', () {
        final data = engine.unicodeFont;
        final b = malloc<Uint8>(data.length);
        try {
          b.asTypedList(data.length).setAll(0, data);
          final f = _p.FPDFText_LoadFont(ctx.doc, b, data.length, FPDF_FONT_TRUETYPE, 1);
          if (f == nullptr) throw const PdfEditException('Unicode font could not be loaded');
          return _Font(f, 'FreeSans (embedded)');
        } finally {
          malloc.free(b);
        }
      });

  void _closeFonts(_ApplyCtx ctx) {
    for (final f in ctx.fonts.values) {
      if (f.owned) _p.FPDFFont_Close(f.handle);
    }
    ctx.fonts.clear();
  }

  static int _segments(Pointer<fpdf_font_t__> font, int cp) {
    final path = _p.FPDFFont_GetGlyphPath(font, cp, 12);
    if (path == nullptr) return 0;
    return _p.FPDFGlyphPath_CountGlyphSegments(path);
  }

  /// True when [font] can draw every character of [text]. Missing glyphs
  /// (typical for subset fonts) resolve to an empty or ".notdef" outline.
  static bool fontCovers(Pointer<fpdf_font_t__> font, String text) {
    if (font == nullptr) return false;
    final notdef = _segments(font, 0xE000);
    for (final r in text.runes.toSet()) {
      if (r == 0x20 || r == 0x09 || r == 0x0a || r == 0xa0) continue;
      if (r > 0xFFFF) return false;
      final s = _segments(font, r);
      if (s <= 0) return false;
      if (notdef > 0 && s == notdef && _sameOutline(font, r, 0xE000)) return false;
    }
    return true;
  }

  static bool _sameOutline(Pointer<fpdf_font_t__> font, int a, int b) => using((al) {
        final wa = al<Float>(), wb = al<Float>();
        final ok1 = _p.FPDFFont_GetGlyphWidth(font, a, 12, wa) != 0;
        final ok2 = _p.FPDFFont_GetGlyphWidth(font, b, 12, wb) != 0;
        return ok1 && ok2 && (wa.value - wb.value).abs() < 0.001;
      });

  static double _measure(Pointer<fpdf_font_t__> font, String s, double size) {
    var w = 0.0;
    using((a) {
      final v = a<Float>();
      for (final r in s.runes) {
        if (_p.FPDFFont_GetGlyphWidth(font, r > 0xFFFF ? 0x3F : r, size, v) != 0) {
          w += v.value;
        } else {
          w += size * 0.5;
        }
      }
    });
    return w;
  }

  static double _ascent(Pointer<fpdf_font_t__> font, double size) => using((a) {
        final v = a<Float>();
        return _p.FPDFFont_GetAscent(font, size, v) != 0 && v.value > 0 ? v.value.toDouble() : size * 0.8;
      });

  /// Chooses the font for text written with [style]. Returns the font and
  /// human-readable notes about substitutions.
  _Font _pickFont(_ApplyCtx ctx, TextStyleSpec style, String text, {TextRunInfo? original, Pointer<fpdf_font_t__>? originalHandle, List<String>? notes}) {
    if (style.font == FontChoice.original && original != null && originalHandle != null && originalHandle != nullptr) {
      final sameStyle = style.bold == original.font.bold && style.italic == original.font.italic;
      if (sameStyle && fontCovers(originalHandle, text)) {
        return _Font(originalHandle, original.font.baseName, owned: false, original: true);
      }
      final fam = familyFor(original.font.family);
      if (!sameStyle) {
        notes?.add('Bold/italic changed, so the original font "${original.font.family}" could not be reused.');
      } else if (original.font.subset) {
        notes?.add('The original font "${original.font.family}" is embedded as a subset and lacks some characters you typed.');
      } else {
        notes?.add('The original font "${original.font.family}" cannot draw some characters you typed.');
      }
      return _fallbackFont(ctx, fam, style, text, notes);
    }
    final fam = style.font == FontChoice.original ? (original != null ? familyFor(original.font.family) : FontChoice.helvetica) : style.font;
    return _fallbackFont(ctx, fam, style, text, notes);
  }

  _Font _fallbackFont(_ApplyCtx ctx, FontChoice fam, TextStyleSpec style, String text, List<String>? notes) {
    if (fam != FontChoice.unicodeSans && _isWinAnsi(text)) {
      final f = _stdFont(ctx, fam, style.bold, style.italic);
      if (style.font == FontChoice.original) notes?.add('Substituted with ${f.name} (closest standard font).');
      return f;
    }
    if (fam != FontChoice.unicodeSans) notes?.add('Characters outside Western European text need the bundled Unicode font (FreeSans).');
    if (style.bold || style.italic) notes?.add('FreeSans is bundled in regular style only; bold/italic is not applied.');
    if (_hasDevanagari(text)) {
      notes?.add('Hindi/Devanagari: conjuncts and vowel signs are not shaped when writing PDF text. Check the preview carefully.');
    }
    return _unicodeFont(ctx);
  }

  // -------------------------------------------------------------------------
  // Writing helpers
  // -------------------------------------------------------------------------

  static void _setText(FPDF_PAGEOBJECT o, String text) {
    final w = text.toNativeUtf16();
    try {
      _p.FPDFText_SetText(o, w.cast());
    } finally {
      malloc.free(w);
    }
  }

  static void _setFill(FPDF_PAGEOBJECT o, int argb, {double alpha = 1}) {
    final a = (((argb >> 24) & 0xFF) * alpha).round().clamp(0, 255);
    _p.FPDFPageObj_SetFillColor(o, (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, a);
  }

  /// Creates text objects for laid-out runs. [firstBaseline] is the
  /// baseline of line 0 in display points, relative to [box].
  List<FPDF_PAGEOBJECT> _writeRuns(FPDF_DOCUMENT doc, _Geom g, _Font font, TextLayoutResult lay, Rect box, double firstBaseline, double size,
      double leading, int color, {double rotation = 0, double alpha = 1, bool invisible = false, double hScale = 1}) {
    final out = <FPDF_PAGEOBJECT>[];
    final center = box.center;
    for (final run in lay.runs) {
      if (run.text.trim().isEmpty) continue;
      final o = _p.FPDFPageObj_CreateTextObj(doc, font.handle, size);
      if (o == nullptr) continue;
      _setText(o, run.text);
      var origin = Offset(box.left + run.x, box.top + firstBaseline + run.line * leading);
      var xAxis = Offset(hScale, 0);
      var yAxis = const Offset(0, -1);
      if (rotation != 0) {
        origin = center + _rotate(origin - center, rotation);
        xAxis = _rotate(xAxis, rotation);
        yAxis = _rotate(yAxis, rotation);
      }
      _setMatrix(o, g.frame(origin, xAxis, yAxis));
      _setFill(o, color, alpha: alpha);
      if (invisible) _p.FPDFTextObj_SetTextRenderMode(o, FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_INVISIBLE);
      out.add(o);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Applying edits to one page
  // -------------------------------------------------------------------------

  /// Applies the content edits of [slot] to [page]. Returns true when new
  /// annotations were created.
  bool _applyPage(_ApplyCtx ctx, FPDF_PAGE page, EditState state, PageSlot slot) {
    final p = _p;
    final g = _geom(page);
    var annots = false;
    if (slot.source != null) {
      final src = slot.source!;
      final n = p.FPDFPage_CountObjects(page);
      final handles = [for (var i = 0; i < n; i++) p.FPDFPage_GetObject(page, i)];
      final toRemove = <FPDF_PAGEOBJECT>{};
      final analysis = analyze(src);
      for (final e in state.textEditsOn(src)) {
        _applyTextEdit(ctx, page, g, handles, toRemove, analysis, e);
      }
      for (final e in state.imageEditsOn(src)) {
        if (e.object < 0 || e.object >= handles.length) continue;
        final o = handles[e.object];
        if (e.deleted) {
          toRemove.add(o);
          continue;
        }
        if (e.replacement != null) {
          final file = File(_resolve(ctx.draftDir, e.replacement!));
          if (file.existsSync()) _loadImageInto(ctx, page, o, file.readAsBytesSync(), e.opacity);
        }
        if (e.box != null) {
          final b = e.box!;
          _setMatrix(o, g.frame(b.bottomLeft, Offset(b.width, 0), Offset(0, -b.height)));
        }
      }
      for (final o in toRemove) {
        if (p.FPDFPage_RemoveObject(page, o) != 0) p.FPDFPageObj_Destroy(o);
      }
    }
    for (final item in state.itemsOn(slot.id)) {
      if (_applyItem(ctx, page, g, item)) annots = true;
    }
    return annots;
  }

  static String _resolve(String a, String b) => p.isAbsolute(b) ? b : p.join(a, b);

  /// Lays out and writes an edited block. Also used by [previewTextEdit].
  TextEditReport _applyTextEdit(_ApplyCtx ctx, FPDF_PAGE page, _Geom g, List<FPDF_PAGEOBJECT> handles, Set<FPDF_PAGEOBJECT> toRemove,
      PageAnalysis analysis, TextBlockEdit e) {
    TextBlockInfo? block;
    for (final b in analysis.blocks) {
      if (b.key == e.key) block = b;
    }
    final valid = e.objects.every((i) => i >= 0 && i < handles.length);
    if (block == null || !valid) {
      ctx.warnings.add('A text edit on page ${e.page + 1} no longer matches the document and was skipped.');
      return TextEditReport(fontUsed: '', originalFontUsed: false, inPlace: false, warnings: const [], outBounds: Rect.zero);
    }
    if (e.deleted) {
      toRemove.addAll(e.objects.map((i) => handles[i]));
      return TextEditReport(fontUsed: '', originalFontUsed: false, inPlace: false, warnings: const [], outBounds: Rect.zero);
    }
    final notes = <String>[];
    final first = block.first;
    final firstHandle = handles[first.object];
    final origFont = _p.FPDFTextObj_GetFont(firstHandle);
    final style = e.style ?? block.originalStyle;
    final text = e.text ?? block.text;
    final styleUnchanged = e.style == null || e.style == block.originalStyle;

    // Fast path: one text object, same line, same formatting -> rewrite the
    // object in place. Its font, size, colour, spacing and position stay.
    if (block.runs.length == 1 && !text.contains('\n') && styleUnchanged && e.box == null && !e.shrinkToFit) {
      if (fontCovers(origFont, text)) {
        _setText(firstHandle, text);
        final b = _objBounds(firstHandle, g);
        return TextEditReport(fontUsed: first.font.baseName, originalFontUsed: true, inPlace: true, warnings: _overlapWarnings(analysis, block, b), outBounds: b);
      }
    }
    if (!block.editableInPlace) {
      notes.add('This text is rotated or skewed; it was rewritten upright.');
    }

    final font = _pickFont(ctx, style, text, original: first, originalHandle: origFont, notes: notes);
    var box = e.box ?? block.bounds;
    if (block.lines.length == 1 && !text.contains('\n') && !e.shrinkToFit && !e.fixedWidth) {
      // A single line (label, heading) grows to the right like in a word
      // processor instead of wrapping.
      box = Rect.fromLTWH(box.left, box.top, math.max(box.width, analysis.size.width - box.left - 18), box.height);
    } else if (!e.fixedWidth) {
      // Glyph bounds are slightly narrower than advance widths; without
      // slack the widest original line could wrap.
      box = Rect.fromLTWH(box.left, box.top, box.width + style.size * 0.6, box.height);
    }
    var size = style.size;
    var leading = style.lineSpacing * size;
    double measure(String s) => _measure(font.handle, s, size);
    var lay = layoutText(text, box.width, style.align, measure);
    // Baseline of the first line relative to the box top.
    double firstBaseline() => size == first.size ? first.baseline.dy - block!.bounds.top : _ascent(font.handle, size);
    var baseline0 = firstBaseline();
    double height() => baseline0 + (lay.lineCount - 1) * leading + size * 0.25;
    if (e.shrinkToFit) {
      final limit = (e.box ?? block.bounds).height + 0.5;
      var guard = 0;
      while (height() > limit && size > style.size * 0.5 && guard++ < 40) {
        size *= 0.95;
        leading = style.lineSpacing * size;
        lay = layoutText(text, box.width, style.align, measure);
        baseline0 = firstBaseline();
      }
      if (size < style.size - 0.01) notes.add('Font size reduced to ${size.toStringAsFixed(1)} pt to fit the original box.');
    }
    if (lay.overflowedWidth) notes.add('A word is wider than the text box and extends past its right edge.');
    toRemove.addAll(e.objects.map((i) => handles[i]));
    final objs = _writeRuns(ctx.doc, g, font, lay, box, baseline0, size, leading, style.color);
    for (final o in objs) {
      _p.FPDFPage_InsertObject(page, o);
    }
    final out = Rect.fromLTWH(box.left, box.top, math.max(box.width, lay.maxLineWidth), height());
    if (out.height > block.bounds.height + size * 0.5 && e.box == null) {
      notes.add('The new text needs more lines than the original paragraph.');
    }
    notes.addAll(_overlapWarnings(analysis, block, out));
    return TextEditReport(fontUsed: font.name, originalFontUsed: font.original, inPlace: false, warnings: notes, outBounds: out);
  }

  static List<String> _overlapWarnings(PageAnalysis a, TextBlockInfo block, Rect out) {
    final hits = <int>{};
    for (final b in a.blocks) {
      if (identical(b, block) || b.key == block.key) continue;
      final inter = b.bounds.intersect(out.deflate(0.5));
      if (inter.width > 1 && inter.height > 1) hits.add(b.page);
    }
    final img = a.images.where((i) {
      final inter = i.bounds.intersect(out.deflate(0.5));
      return inter.width > 1 && inter.height > 1 && i.bounds.width * i.bounds.height < a.size.width * a.size.height * 0.5;
    });
    return [
      if (hits.isNotEmpty) 'The edited text overlaps neighbouring text. Resize the box or reduce the font size.',
      if (img.isNotEmpty) 'The edited text overlaps an image.',
    ];
  }

  // -------------------------------------------------------------------------
  // Images
  // -------------------------------------------------------------------------

  /// Loads an encoded image into [obj]. JPEGs without transparency changes
  /// are embedded unchanged (no recompression); other images are embedded
  /// losslessly with their alpha channel.
  void _loadImageInto(_ApplyCtx ctx, FPDF_PAGE page, FPDF_PAGEOBJECT obj, Uint8List data, double opacity) {
    final p = _p;
    final isJpeg = data.length > 3 && data[0] == 0xFF && data[1] == 0xD8;
    final pages = malloc<FPDF_PAGE>();
    pages.value = page;
    try {
      if (isJpeg && opacity >= 0.999) {
        if (_loadJpeg(pages, obj, data)) return;
      }
      final decoded = img.decodeImage(data);
      if (decoded == null) throw const PdfEditException('Unsupported image format.');
      final rgba = decoded.convert(numChannels: 4);
      final w = rgba.width, h = rgba.height;
      final buf = malloc<Uint8>(w * h * 4);
      try {
        final bytes = buf.asTypedList(w * h * 4);
        var k = 0;
        for (final px in rgba) {
          bytes[k++] = px.b.toInt();
          bytes[k++] = px.g.toInt();
          bytes[k++] = px.r.toInt();
          bytes[k++] = (px.a.toInt() * opacity).round().clamp(0, 255);
        }
        final bmp = p.FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA, buf.cast(), w * 4);
        try {
          if (p.FPDFImageObj_SetBitmap(pages, 1, obj, bmp) == 0) throw const PdfEditException('Image could not be embedded.');
        } finally {
          p.FPDFBitmap_Destroy(bmp);
        }
      } finally {
        malloc.free(buf);
      }
    } finally {
      malloc.free(pages);
    }
  }

  static Uint8List? _jpegData;

  static int _getBlock(Pointer<Void> param, int position, Pointer<UnsignedChar> pBuf, int size) {
    final d = _jpegData;
    if (d == null || position + size > d.length) return 0;
    pBuf.cast<Uint8>().asTypedList(size).setAll(0, Uint8List.sublistView(d, position, position + size));
    return 1;
  }

  bool _loadJpeg(Pointer<FPDF_PAGE> pages, FPDF_PAGEOBJECT obj, Uint8List data) {
    final cb = NativeCallable<Int Function(Pointer<Void>, UnsignedLong, Pointer<UnsignedChar>, UnsignedLong)>.isolateLocal(_getBlock, exceptionalReturn: 0);
    final fa = malloc<FPDF_FILEACCESS>();
    _jpegData = data;
    try {
      fa.ref
        ..m_FileLen = data.length
        ..m_GetBlock = cb.nativeFunction
        ..m_Param = nullptr;
      return _p.FPDFImageObj_LoadJpegFileInline(pages, 1, obj, fa) != 0;
    } finally {
      _jpegData = null;
      malloc.free(fa);
      cb.close();
    }
  }

  // -------------------------------------------------------------------------
  // Added items
  // -------------------------------------------------------------------------

  bool _applyItem(_ApplyCtx ctx, FPDF_PAGE page, _Geom g, EditItem it) {
    final p = _p;
    switch (it.kind) {
      case ItemKind.text:
        final notes = <String>[];
        final font = _pickFont(ctx, it.style, it.text, notes: notes);
        final size = it.style.size;
        final lay = layoutText(it.text, it.box.width, it.style.align, (s) => _measure(font.handle, s, size));
        for (final o in _writeRuns(ctx.doc, g, font, lay, it.box, _ascent(font.handle, size), size, it.style.lineSpacing * size, it.style.color,
            rotation: it.rotation, alpha: it.opacity)) {
          p.FPDFPage_InsertObject(page, o);
        }
        return false;
      case ItemKind.ocrText:
        // Invisible, searchable text stretched over the recognised line.
        final font = _unicodeFont(ctx);
        final size = math.max(1.0, it.box.height * 0.8);
        final w = _measure(font.handle, it.text, size);
        final lay = TextLayoutResult([LaidOutRun(it.text, 0, 0)], 1, w, false);
        for (final o in _writeRuns(ctx.doc, g, font, lay, it.box, it.box.height * 0.8, size, size, 0xFF000000,
            invisible: true, hScale: w > 0 ? it.box.width / w : 1)) {
          p.FPDFPage_InsertObject(page, o);
        }
        return false;
      case ItemKind.image:
        final file = it.asset == null ? null : File(_resolve(ctx.draftDir, it.asset!));
        if (file == null || !file.existsSync()) {
          ctx.warnings.add('An inserted image file is missing and was skipped.');
          return false;
        }
        final o = p.FPDFPageObj_NewImageObj(ctx.doc);
        _loadImageInto(ctx, page, o, file.readAsBytesSync(), it.opacity);
        final b = it.box;
        var origin = b.bottomLeft;
        var xa = Offset(b.width, 0);
        var ya = Offset(0, -b.height);
        if (it.rotation != 0) {
          origin = b.center + _rotate(origin - b.center, it.rotation);
          xa = _rotate(xa, it.rotation);
          ya = _rotate(ya, it.rotation);
        }
        _setMatrix(o, g.frame(origin, xa, ya));
        p.FPDFPage_InsertObject(page, o);
        return false;
      case ItemKind.cover:
        final (l, b, r, t) = g.rectToUser(it.box);
        final o = p.FPDFPageObj_CreateNewRect(l, b, r - l, t - b);
        _setFill(o, it.color);
        p.FPDFPath_SetDrawMode(o, FPDF_FILLMODE_WINDING, 0);
        p.FPDFPage_InsertObject(page, o);
        return false;
      default:
        _createAnnotation(ctx, page, g, it);
        return true;
    }
  }

  void _annotColor(FPDF_ANNOTATION a, int argb, {FPDFANNOT_COLORTYPE type = FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color}) {
    _p.FPDFAnnot_SetColor(a, type, (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF);
  }

  void _annotRect(FPDF_ANNOTATION a, _Geom g, Rect r) => using((al) {
        final (l, b, rr, t) = g.rectToUser(r);
        final f = al<FS_RECTF>();
        f.ref
          ..left = l
          ..bottom = b
          ..right = rr
          ..top = t;
        _p.FPDFAnnot_SetRect(a, f);
      });

  void _setAnnotString(FPDF_ANNOTATION a, String key, String value) {
    final k = key.toNativeUtf8();
    final v = value.toNativeUtf16();
    try {
      _p.FPDFAnnot_SetStringValue(a, k.cast(), v.cast());
    } finally {
      malloc.free(k);
      malloc.free(v);
    }
  }

  void _createAnnotation(_ApplyCtx ctx, FPDF_PAGE page, _Geom g, EditItem it) {
    final p = _p;
    final subtype = switch (it.kind) {
      ItemKind.highlight => FPDF_ANNOT_HIGHLIGHT,
      ItemKind.underline => FPDF_ANNOT_UNDERLINE,
      ItemKind.strikeout => FPDF_ANNOT_STRIKEOUT,
      ItemKind.note => FPDF_ANNOT_TEXT,
      ItemKind.rect => FPDF_ANNOT_SQUARE,
      ItemKind.ellipse => FPDF_ANNOT_CIRCLE,
      ItemKind.stamp => FPDF_ANNOT_STAMP,
      _ => FPDF_ANNOT_INK,
    };
    final a = p.FPDFPage_CreateAnnot(page, subtype);
    if (a == nullptr) {
      ctx.warnings.add('A ${it.kind.label.toLowerCase()} annotation could not be created.');
      return;
    }
    try {
      p.FPDFAnnot_SetFlags(a, FPDF_ANNOT_FLAG_PRINT);
      _setAnnotString(a, 'T', 'ScanPro Studio');
      final date = _pdfDate(DateTime.now());
      _setAnnotString(a, 'M', date);
      switch (it.kind) {
        case ItemKind.highlight:
        case ItemKind.underline:
        case ItemKind.strikeout:
          _annotColor(a, it.color);
          final rects = it.rects.isEmpty ? [it.box] : it.rects;
          using((al) {
            final q = al<FS_QUADPOINTSF>();
            for (final r in rects) {
              final (x1, y1) = g.toUser(r.topLeft);
              final (x2, y2) = g.toUser(r.topRight);
              final (x3, y3) = g.toUser(r.bottomLeft);
              final (x4, y4) = g.toUser(r.bottomRight);
              q.ref
                ..x1 = x1
                ..y1 = y1
                ..x2 = x2
                ..y2 = y2
                ..x3 = x3
                ..y3 = y3
                ..x4 = x4
                ..y4 = y4;
              p.FPDFAnnot_AppendAttachmentPoints(a, q);
            }
          });
          _annotRect(a, g, rects.reduce((x, y) => x.expandToInclude(y)));
          if (it.text.isNotEmpty) _setAnnotString(a, 'Contents', it.text);
        case ItemKind.note:
          _annotColor(a, it.color);
          _annotRect(a, g, Rect.fromLTWH(it.box.left, it.box.top, 20, 20));
          _setAnnotString(a, 'Contents', it.text);
        case ItemKind.rect:
        case ItemKind.ellipse:
          _annotColor(a, it.color);
          p.FPDFAnnot_SetBorder(a, 0, 0, it.strokeWidth);
          _annotRect(a, g, it.box);
          if (it.text.isNotEmpty) _setAnnotString(a, 'Contents', it.text);
        case ItemKind.ink:
        case ItemKind.line:
        case ItemKind.arrow:
          _annotColor(a, it.color);
          p.FPDFAnnot_SetBorder(a, 0, 0, it.strokeWidth);
          final strokes = it.kind == ItemKind.arrow ? _arrowStrokes(it) : it.strokes;
          var bounds = it.box;
          for (final s in strokes) {
            if (s.length < 2) continue;
            for (final pt in s) {
              bounds = bounds.expandToInclude(Rect.fromCenter(center: pt, width: 1, height: 1));
            }
            using((al) {
              final pts = al<FS_POINTF>(s.length);
              for (var i = 0; i < s.length; i++) {
                final (x, y) = g.toUser(s[i]);
                pts[i]
                  ..x = x
                  ..y = y;
              }
              p.FPDFAnnot_AddInkStroke(a, pts, s.length);
            });
          }
          _annotRect(a, g, bounds.inflate(it.strokeWidth));
        case ItemKind.stamp:
          _annotRect(a, g, it.box);
          _setAnnotString(a, 'Contents', it.text.isEmpty ? 'Stamp' : it.text);
          _buildStampAppearance(ctx, page, g, a, it);
        default:
          break;
      }
    } finally {
      p.FPDFPage_CloseAnnot(a);
    }
  }

  static String _pdfDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'D:${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  static List<List<Offset>> _arrowStrokes(EditItem it) {
    if (it.strokes.isEmpty || it.strokes.first.length < 2) return it.strokes;
    final s = it.strokes.first;
    final a = s.first, b = s.last;
    final dir = b - a;
    if (dir.distance == 0) return [s];
    final u = dir / dir.distance;
    final head = math.max(8.0, it.strokeWidth * 4);
    final left = b - _rotate(u, -30) * head;
    final right = b - _rotate(u, 30) * head;
    return [
      [a, b],
      [left, b, right],
    ];
  }

  void _buildStampAppearance(_ApplyCtx ctx, FPDF_PAGE page, _Geom g, FPDF_ANNOTATION a, EditItem it) {
    final p = _p;
    final b = it.box;
    if (it.asset != null) {
      final file = File(_resolve(ctx.draftDir, it.asset!));
      if (file.existsSync()) {
        final o = p.FPDFPageObj_NewImageObj(ctx.doc);
        _loadImageInto(ctx, page, o, file.readAsBytesSync(), it.opacity);
        _setMatrix(o, g.frame(b.bottomLeft, Offset(b.width, 0), Offset(0, -b.height)));
        if (p.FPDFAnnot_AppendObject(a, o) == 0) p.FPDFPageObj_Destroy(o);
        return;
      }
    }
    // Text stamp: rounded border and the label in bold.
    final (l, bt, r, t) = g.rectToUser(b.deflate(1.5));
    final rect = p.FPDFPageObj_CreateNewRect(l, bt, r - l, t - bt);
    p.FPDFPageObj_SetStrokeColor(rect, (it.color >> 16) & 0xFF, (it.color >> 8) & 0xFF, it.color & 0xFF, (255 * it.opacity).round());
    p.FPDFPageObj_SetStrokeWidth(rect, 2.5);
    p.FPDFPath_SetDrawMode(rect, FPDF_FILLMODE_NONE, 1);
    if (p.FPDFAnnot_AppendObject(a, rect) == 0) p.FPDFPageObj_Destroy(rect);
    final label = it.text.isEmpty ? 'STAMP' : it.text;
    final font = _isWinAnsi(label) ? _stdFont(ctx, FontChoice.helvetica, true, false) : _unicodeFont(ctx);
    var size = b.height * 0.5;
    final w = _measure(font.handle, label, size);
    if (w > b.width * 0.85) size *= b.width * 0.85 / w;
    final tw = _measure(font.handle, label, size);
    final o = p.FPDFPageObj_CreateTextObj(ctx.doc, font.handle, size);
    _setText(o, label);
    _setMatrix(o, g.frame(Offset(b.left + (b.width - tw) / 2, b.top + b.height / 2 + size * 0.35), const Offset(1, 0), const Offset(0, -1)));
    _setFill(o, it.color, alpha: it.opacity);
    if (p.FPDFAnnot_AppendObject(a, o) == 0) p.FPDFPageObj_Destroy(o);
  }

  // -------------------------------------------------------------------------
  // Decorations (watermark, header, footer, page numbers)
  // -------------------------------------------------------------------------

  void _applyDecorations(_ApplyCtx ctx, FPDF_PAGE page, Decorations d, int number, int total) {
    final p = _p;
    final g = _geom(page);
    final sz = g.display;
    void line(String text, double y, TextAlign2 align, {double size = 0}) {
      if (text.trim().isEmpty) return;
      final fs = size > 0 ? size : d.fontSize;
      final style = TextStyleSpec(size: fs, color: 0xFF333333, align: align);
      final font = _pickFont(ctx, style, text);
      final margin = 36.0;
      final box = Rect.fromLTWH(margin, y, sz.width - 2 * margin, fs * 1.4);
      final lay = layoutText(text, box.width, align, (s) => _measure(font.handle, s, fs));
      for (final o in _writeRuns(ctx.doc, g, font, lay, box, _ascent(font.handle, fs), fs, fs * 1.2, style.color)) {
        p.FPDFPage_InsertObject(page, o);
      }
    }

    String fill(String s) => s.replaceAll('{n}', '$number').replaceAll('{total}', '$total');
    line(fill(d.header), 18, TextAlign2.center);
    line(fill(d.footer), sz.height - 18 - d.fontSize * 1.4, TextAlign2.center);
    if (d.pageNumbers) line(fill(d.pageNumberFormat), sz.height - 18 - d.fontSize * 1.4, TextAlign2.right);
    if (d.watermark.trim().isNotEmpty) {
      final text = d.watermark.trim();
      final style = TextStyleSpec(bold: true, color: d.watermarkColor);
      final font = _pickFont(ctx, style, text);
      var size = math.min(sz.width, sz.height) / 8;
      final diag = math.sqrt(sz.width * sz.width + sz.height * sz.height);
      final w = _measure(font.handle, text, size);
      if (w > diag * 0.8) size *= diag * 0.8 / w;
      final tw = _measure(font.handle, text, size);
      final angle = -math.atan2(sz.height, sz.width) * 180 / math.pi;
      final box = Rect.fromCenter(center: sz.center(Offset.zero), width: tw, height: size);
      final lay = TextLayoutResult([LaidOutRun(text, 0, 0)], 1, tw, false);
      for (final o in _writeRuns(ctx.doc, g, font, lay, box, size * 0.75, size, size, d.watermarkColor, rotation: angle, alpha: d.watermarkOpacity)) {
        p.FPDFPage_InsertObject(page, o);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Preview
  // -------------------------------------------------------------------------

  @override
  TextEditReport previewTextEdit(TextBlockEdit edit) {
    final p = _p;
    final doc = _loadCopy();
    final ctx = _ApplyCtx(doc, '');
    try {
      final page = _loadPage(doc, edit.page);
      try {
        final n = p.FPDFPage_CountObjects(page);
        final handles = [for (var i = 0; i < n; i++) p.FPDFPage_GetObject(page, i)];
        return _applyTextEdit(ctx, page, _geom(page), handles, <FPDF_PAGEOBJECT>{}, analyze(edit.page), edit);
      } finally {
        p.FPDF_ClosePage(page);
      }
    } finally {
      _closeFonts(ctx);
      p.FPDF_CloseDocument(doc);
    }
  }

  @override
  ({Uint8List rgba, int width, int height}) render(EditState state, String slotId, double scale, {bool original = false, String draftDir = ''}) {
    final p = _p;
    final slot = state.slot(slotId);
    if (slot == null) throw PdfEditException('Unknown page $slotId');
    final needsEdits = !original && (state.slotHasContentEdits(slot) || !state.decorations.isEmpty);
    if (!needsEdits && !slot.isBlank) {
      final page = _loadPage(_ref, slot.source!);
      try {
        return _renderPage(page, scale);
      } finally {
        p.FPDF_ClosePage(page);
      }
    }
    final doc = _loadCopy();
    final ctx = _ApplyCtx(doc, draftDir);
    try {
      final FPDF_PAGE page;
      if (slot.isBlank) {
        page = p.FPDFPage_New(doc, p.FPDF_GetPageCount(doc), slot.blankSize.width, slot.blankSize.height);
      } else {
        page = _loadPage(doc, slot.source!);
      }
      try {
        if (!original) {
          _applyPage(ctx, page, state, slot);
          if (!state.decorations.isEmpty) {
            // Preview numbering follows the current page order.
            _applyDecorations(ctx, page, state.decorations, state.slots.indexOf(slot) + 1, state.slots.length);
          }
        }
        return _renderPage(page, scale);
      } finally {
        p.FPDF_ClosePage(page);
      }
    } finally {
      _closeFonts(ctx);
      p.FPDF_CloseDocument(doc);
    }
  }

  ({Uint8List rgba, int width, int height}) _renderPage(FPDF_PAGE page, double scale) {
    final p = _p;
    final size = _geom(page).display;
    final w = math.max(1, (size.width * scale).round());
    final h = math.max(1, (size.height * scale).round());
    final bmp = p.FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA, nullptr, 0);
    if (bmp == nullptr) throw const PdfEditException('Not enough memory to render the page.');
    try {
      p.FPDFBitmap_FillRect(bmp, 0, 0, w, h, 0xFFFFFFFF);
      p.FPDF_RenderPageBitmap(bmp, page, 0, 0, w, h, 0, FPDF_ANNOT);
      final stride = p.FPDFBitmap_GetStride(bmp);
      final src = p.FPDFBitmap_GetBuffer(bmp).cast<Uint8>().asTypedList(stride * h);
      final out = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        var s = y * stride, d = y * w * 4;
        for (var x = 0; x < w; x++, s += 4, d += 4) {
          out[d] = src[s + 2];
          out[d + 1] = src[s + 1];
          out[d + 2] = src[s];
          out[d + 3] = 255;
        }
      }
      return (rgba: out, width: w, height: h);
    } finally {
      p.FPDFBitmap_Destroy(bmp);
    }
  }

  // -------------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------------

  @override
  ExportResult export(EditState state, {ExportOptions options = const ExportOptions(), String draftDir = ''}) {
    final p = _p;
    if (state.slots.isEmpty) throw const PdfEditException('The document has no pages left.');
    final doc = _loadCopy();
    final ctx = _ApplyCtx(doc, draftDir);
    try {
      final original = p.FPDF_GetPageCount(doc);
      // 1. Blank pages are appended; remember where each slot lives.
      final indexOf = <String, int>{};
      for (final s in state.slots) {
        if (s.isBlank) {
          final idx = p.FPDF_GetPageCount(doc);
          final pg = p.FPDFPage_New(doc, idx, s.blankSize.width, s.blankSize.height);
          p.FPDF_ClosePage(pg);
          indexOf[s.id] = idx;
        } else {
          indexOf[s.id] = s.source!;
        }
      }
      final kept = options.onlySlots == null ? state.slots : [for (final i in options.onlySlots!) if (i >= 0 && i < state.slots.length) state.slots[i]];
      if (kept.isEmpty) throw const PdfEditException('No pages selected.');
      // Existing annotations on kept original pages, to check nothing is lost.
      var annotsBefore = 0;
      for (final s in kept) {
        if (s.isBlank) continue;
        final pg = _loadPage(doc, s.source!);
        annotsBefore += p.FPDFPage_GetAnnotCount(pg);
        p.FPDF_ClosePage(pg);
      }
      // 2. Content edits.
      var added = 0;
      for (final s in kept) {
        final rot = s.rotation ~/ 90;
        if (!state.slotHasContentEdits(s) && rot == 0) continue;
        final pg = _loadPage(doc, indexOf[s.id]!);
        try {
          if (state.slotHasContentEdits(s)) {
            final before = p.FPDFPage_GetAnnotCount(pg);
            final annots = _applyPage(ctx, pg, state, s);
            if (p.FPDFPage_GenerateContent(pg) == 0) ctx.warnings.add('Page content could not be regenerated for one page.');
            added += p.FPDFPage_GetAnnotCount(pg) - before;
            if (annots) {
              // Rendering builds appearance streams for new annotations so
              // every viewer shows them and flattening works.
              _renderTiny(pg);
            }
          }
          if (rot != 0) p.FPDFPage_SetRotation(pg, (p.FPDFPage_GetRotation(pg) + rot) % 4);
        } finally {
          p.FPDF_ClosePage(pg);
        }
      }
      // 3. Delete pages that are not kept, then order the rest.
      final keep = [for (final s in kept) indexOf[s.id]!];
      final total = p.FPDF_GetPageCount(doc);
      final drop = [for (var i = 0; i < total; i++) if (!keep.contains(i)) i]..sort((a, b) => b.compareTo(a));
      for (final i in drop) {
        p.FPDFPage_Delete(doc, i);
      }
      final remaining = [for (var i = 0; i < total; i++) if (keep.contains(i)) i];
      final order = [for (final k in keep) remaining.indexOf(k)];
      var identity = true;
      for (var i = 0; i < order.length; i++) {
        if (order[i] != i) identity = false;
      }
      if (!identity) {
        final ptr = malloc<Int>(order.length);
        try {
          for (var i = 0; i < order.length; i++) {
            ptr[i] = order[i];
          }
          if (p.FPDF_MovePages(doc, ptr, order.length, 0) == 0) throw const PdfEditException('Pages could not be reordered.');
        } finally {
          malloc.free(ptr);
        }
      }
      // 4. Decorations and flattening on the final pages.
      final finalCount = p.FPDF_GetPageCount(doc);
      if (!state.decorations.isEmpty || options.flattenAnnotations) {
        for (var i = 0; i < finalCount; i++) {
          final pg = _loadPage(doc, i);
          try {
            if (!state.decorations.isEmpty) {
              _applyDecorations(ctx, pg, state.decorations, i + 1, finalCount);
              p.FPDFPage_GenerateContent(pg);
            }
            if (options.flattenAnnotations) {
              _renderTiny(pg);
              p.FPDFPage_Flatten(pg, FLAT_PRINT);
            }
          } finally {
            p.FPDF_ClosePage(pg);
          }
        }
      }
      _closeFonts(ctx);
      // 5. Save.
      final removeSecurity = encrypted && !options.keepEncryption;
      final bytes = _save(doc, removeSecurity ? FPDF_REMOVE_SECURITY : FPDF_NO_INCREMENTAL);
      if (original == 0) ctx.warnings.add('The original had no pages.');
      // 6. Validate by re-opening the written file.
      return _validate(bytes, finalCount, ctx.warnings,
          annotsBefore: annotsBefore, added: options.flattenAnnotations ? null : added, expectEncrypted: encrypted && !removeSecurity);
    } finally {
      _closeFonts(ctx);
      p.FPDF_CloseDocument(doc);
    }
  }

  void _renderTiny(FPDF_PAGE pg) {
    final p = _p;
    final bmp = p.FPDFBitmap_CreateEx(4, 4, FPDFBitmap_BGRA, nullptr, 0);
    if (bmp == nullptr) return;
    p.FPDF_RenderPageBitmap(bmp, pg, 0, 0, 4, 4, 0, FPDF_ANNOT);
    p.FPDFBitmap_Destroy(bmp);
  }

  static BytesBuilder? _sink;

  static int _writeBlock(Pointer<FPDF_FILEWRITE_> self, Pointer<Void> data, int size) {
    final s = _sink;
    if (s == null) return 0;
    s.add(Uint8List.fromList(data.cast<Uint8>().asTypedList(size)));
    return 1;
  }

  /// Re-writes a damaged file: PDFium rebuilds broken cross-reference
  /// tables when opening, and saving writes a clean structure.
  static Uint8List repair(Uint8List bytes, {String? password}) {
    final buf = malloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final doc = _load(buf, bytes.length, password);
      if (doc == nullptr) {
        final err = _p.FPDF_GetLastError();
        if (err == 4) throw EditorPasswordRequired(wrong: password != null);
        throw const PdfEditException('The file is too damaged to be repaired.');
      }
      try {
        if (_p.FPDF_GetPageCount(doc) == 0) throw const PdfEditException('No pages could be recovered from this file.');
        return _saveDoc(doc, FPDF_NO_INCREMENTAL);
      } finally {
        _p.FPDF_CloseDocument(doc);
      }
    } finally {
      malloc.free(buf);
    }
  }

  Uint8List _save(FPDF_DOCUMENT doc, int flags) => _saveDoc(doc, flags);

  static Uint8List _saveDoc(FPDF_DOCUMENT doc, int flags) {
    final cb = NativeCallable<Int Function(Pointer<FPDF_FILEWRITE_>, Pointer<Void>, UnsignedLong)>.isolateLocal(_writeBlock, exceptionalReturn: 0);
    final fw = malloc<FPDF_FILEWRITE_>();
    final sink = BytesBuilder(copy: false);
    _sink = sink;
    try {
      fw.ref
        ..version = 1
        ..WriteBlock = cb.nativeFunction;
      if (_p.FPDF_SaveAsCopy(doc, fw.cast(), flags) == 0) throw const PdfEditException('Saving the PDF failed.');
      return sink.toBytes();
    } finally {
      _sink = null;
      malloc.free(fw);
      cb.close();
    }
  }

  ExportResult _validate(Uint8List bytes, int expectedPages, List<String> warnings, {required int annotsBefore, int? added, required bool expectEncrypted}) {
    final p = _p;
    if (bytes.length < 8 || String.fromCharCodes(bytes.sublist(0, 5)) != '%PDF-') {
      throw const PdfEditException('Validation failed: the written file is not a PDF.');
    }
    final buf = malloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final doc = _load(buf, bytes.length, expectEncrypted ? password : null);
      if (doc == nullptr) throw const PdfEditException('Validation failed: the written file could not be re-opened.');
      try {
        final count = p.FPDF_GetPageCount(doc);
        if (count != expectedPages) throw PdfEditException('Validation failed: expected $expectedPages pages, found $count.');
        var annots = 0;
        for (var i = 0; i < count; i++) {
          final pg = p.FPDF_LoadPage(doc, i);
          if (pg == nullptr) throw PdfEditException('Validation failed: page ${i + 1} cannot be loaded.');
          annots += p.FPDFPage_GetAnnotCount(pg);
          p.FPDF_ClosePage(pg);
        }
        final enc = p.FPDF_GetSecurityHandlerRevision(doc) != -1;
        final after = added == null ? annots : annots - added;
        if (added != null && after < annotsBefore) {
          warnings.add('${annotsBefore - after} existing annotation(s), link(s) or form field(s) were not preserved.');
        }
        return ExportResult(bytes, count, warnings, annotationsBefore: annotsBefore, annotationsAfter: after, encrypted: enc);
      } finally {
        p.FPDF_CloseDocument(doc);
      }
    } finally {
      malloc.free(buf);
    }
  }

  /// Text of every page of [bytes] as PDFium extracts it (used to index
  /// edited documents for search).
  static List<String> pageTexts(Uint8List bytes, {String? password}) {
    final p = _p;
    final buf = malloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final doc = _load(buf, bytes.length, password);
      if (doc == nullptr) return const [];
      try {
        final out = <String>[];
        for (var i = 0; i < p.FPDF_GetPageCount(doc); i++) {
          final pg = p.FPDF_LoadPage(doc, i);
          if (pg == nullptr) {
            out.add('');
            continue;
          }
          final tp = p.FPDFText_LoadPage(pg);
          try {
            final n = p.FPDFText_CountChars(tp);
            if (n <= 0) {
              out.add('');
              continue;
            }
            final b = malloc<Uint16>(n + 1);
            try {
              final got = p.FPDFText_GetText(tp, 0, n, b.cast());
              out.add(String.fromCharCodes(b.asTypedList(math.max(0, got - 1))));
            } finally {
              malloc.free(b);
            }
          } finally {
            p.FPDFText_ClosePage(tp);
            p.FPDF_ClosePage(pg);
          }
        }
        return out;
      } finally {
        p.FPDF_CloseDocument(doc);
      }
    } finally {
      malloc.free(buf);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _p.FPDF_CloseDocument(_ref);
    malloc.free(_buf);
  }
}
