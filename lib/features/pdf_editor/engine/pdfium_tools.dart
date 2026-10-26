part of 'pdfium_engine.dart';

/// Read-only tools on a PDFium session used by the reader and the
/// converters: structured content, images, rendering, outline, search and
/// annotation listing.
class PdfOutlineItem {
  final String title;
  final int? page; // null when the destination is not a page in this file
  final int level;
  const PdfOutlineItem(this.title, this.page, this.level);
}

class PdfSearchHit {
  final int page;
  final List<Rect> rects; // display points
  final String context;
  const PdfSearchHit(this.page, this.rects, this.context);
}

class PdfAnnotInfo {
  final int page;
  final String subtype;
  final Rect rect;
  final String contents;
  final String author;
  const PdfAnnotInfo(this.page, this.subtype, this.rect, this.contents, this.author);
}

enum RasterFormat { jpg, png, tiff }

const _annotNames = {
  1: 'Text note',
  2: 'Link',
  3: 'Free text',
  4: 'Line',
  5: 'Square',
  6: 'Circle',
  7: 'Polygon',
  8: 'Polyline',
  9: 'Highlight',
  10: 'Underline',
  11: 'Squiggly',
  12: 'Strikeout',
  13: 'Stamp',
  14: 'Caret',
  15: 'Ink',
  16: 'Popup',
  17: 'File attachment',
  18: 'Sound',
  19: 'Movie',
  20: 'Widget (form field)',
  21: 'Screen',
  22: 'Printer mark',
  23: 'Trap net',
  24: 'Watermark',
  25: '3D',
  26: 'Rich media',
  27: 'XFA widget',
  28: 'Redact',
};

extension PdfiumTools on PdfiumSession {
  PDFium get _lib => PdfiumSession._p;

  // -------------------------------------------------------------------------
  // Structured content
  // -------------------------------------------------------------------------

  /// Words (with font size, weight, italic, colour), images and ruling
  /// lines of a page.
  PageContent content(int pageIndex, {bool images = true, int maxImageSide = 2000}) {
    final p = _lib;
    final page = _loadPage(_ref, pageIndex);
    final tp = p.FPDFText_LoadPage(page);
    try {
      final g = PdfiumSession._geom(page);
      final words = <PdfWord>[];
      final n = p.FPDFText_CountChars(tp);
      final fontCache = <int, (String, bool, bool)>{};
      using((a) {
        final l = a<Double>(), r = a<Double>(), b = a<Double>(), t = a<Double>();
        final cr = a<UnsignedInt>(), cg = a<UnsignedInt>(), cb = a<UnsignedInt>(), ca = a<UnsignedInt>();
        final flags = a<Int>();
        final nameBuf = a<Uint8>(256);
        final sb = StringBuffer();
        Rect? box;
        double size = 0;
        var bold = false, italic = false;
        var color = 0xFF000000;
        var font = '';
        void flush() {
          final s = sb.toString();
          if (s.trim().isNotEmpty && box != null) {
            words.add(PdfWord(s, box!, size: size, bold: bold, italic: italic, color: color, font: font));
          }
          sb.clear();
          box = null;
        }

        for (var i = 0; i < n; i++) {
          final u = p.FPDFText_GetUnicode(tp, i);
          if (u <= 0x20 || u == 0xA0 || u == 0xFFFE || u == 0xFFFF) {
            flush();
            continue;
          }
          if (p.FPDFText_GetCharBox(tp, i, l, r, b, t) == 0) continue;
          var cbox = g.rectToDisplay(l.value, b.value, r.value, t.value);
          final fs = p.FPDFText_GetFontSize(tp, i);
          if (cbox.height < 0.1) cbox = Rect.fromLTWH(cbox.left, cbox.top - fs * 0.7, math.max(cbox.width, fs * 0.3), fs * 0.7);
          // A large gap or a baseline change starts a new word.
          if (box != null) {
            final gap = cbox.left - box!.right;
            final dy = (cbox.bottom - box!.bottom).abs();
            if (gap > fs * 0.3 || gap < -fs * 2 || dy > fs * 0.6) flush();
          }
          final obj = p.FPDFText_GetTextObject(tp, i);
          final key = obj.address;
          final info = fontCache.putIfAbsent(key, () {
            final len = p.FPDFText_GetFontInfo(tp, i, nameBuf.cast(), 256, flags);
            var name = '';
            if (len > 1) name = String.fromCharCodes(nameBuf.asTypedList(math.min(255, len - 1)));
            final weight = p.FPDFText_GetFontWeight(tp, i);
            final lower = name.toLowerCase();
            final isBold = weight >= 600 || lower.contains('bold') || lower.contains('black') || lower.contains('heavy');
            final isItalic = (flags.value & (1 << 6)) != 0 || lower.contains('italic') || lower.contains('oblique');
            return (name.replaceFirst(RegExp(r'^[A-Z]{6}\+'), ''), isBold, isItalic);
          });
          if (box == null) {
            size = fs;
            (font, bold, italic) = info;
            color = p.FPDFText_GetFillColor(tp, i, cr, cg, cb, ca) != 0 ? (0xFF000000 | (cr.value << 16) | (cg.value << 8) | cb.value) : 0xFF000000;
            box = cbox;
          } else {
            box = box!.expandToInclude(cbox);
          }
          sb.writeCharCode(u);
        }
        flush();
      });
      final imgs = <PdfImageBlock>[];
      final rules = <PdfRule>[];
      var imageArea = 0.0;
      final size = g.display;
      final count = p.FPDFPage_CountObjects(page);
      for (var i = 0; i < count; i++) {
        final o = p.FPDFPage_GetObject(page, i);
        final type = p.FPDFPageObj_GetType(o);
        if (type == FPDF_PAGEOBJ_IMAGE) {
          final bx = PdfiumSession._objBounds(o, g);
          final clipped = bx.intersect(Offset.zero & size);
          if (clipped.width > 0 && clipped.height > 0) imageArea += clipped.width * clipped.height;
          if (!images || bx.width < 4 || bx.height < 4) continue;
          final png = _imagePng(page, o, maxImageSide);
          if (png != null) imgs.add(PdfImageBlock(bx, png.$1, png.$2, png.$3));
        } else if (type == FPDF_PAGEOBJ_PATH) {
          final bx = PdfiumSession._objBounds(o, g);
          if (bx.width > size.width * 0.95 && bx.height > size.height * 0.95) continue;
          if (bx.height <= 2 && bx.width > 6) {
            rules.add(PdfRule(Offset(bx.left, bx.center.dy), Offset(bx.right, bx.center.dy)));
          } else if (bx.width <= 2 && bx.height > 6) {
            rules.add(PdfRule(Offset(bx.center.dx, bx.top), Offset(bx.center.dx, bx.bottom)));
          } else if (p.FPDFPath_CountSegments(o) <= 6 && bx.width > 6 && bx.height > 4 && bx.width * bx.height < size.width * size.height * 0.5) {
            // A rectangle: its edges may be cell borders.
            rules.addAll([
              PdfRule(bx.topLeft, bx.topRight),
              PdfRule(bx.bottomLeft, bx.bottomRight),
              PdfRule(bx.topLeft, bx.bottomLeft),
              PdfRule(bx.topRight, bx.bottomRight),
            ]);
          }
        }
      }
      final scanned = words.isEmpty && imageArea > size.width * size.height * 0.5;
      return PageContent(index: pageIndex, size: size, lines: groupWordsIntoLines(words), images: imgs, rules: rules, scanned: scanned);
    } finally {
      p.FPDFText_ClosePage(tp);
      p.FPDF_ClosePage(page);
    }
  }

  /// The image as drawn (masks applied), as PNG, downscaled to [maxSide].
  (Uint8List, int, int)? _imagePng(FPDF_PAGE page, FPDF_PAGEOBJECT obj, int maxSide) {
    final p = _lib;
    final bmp = p.FPDFImageObj_GetRenderedBitmap(_ref, page, obj);
    if (bmp == nullptr) return null;
    try {
      final w = p.FPDFBitmap_GetWidth(bmp), h = p.FPDFBitmap_GetHeight(bmp);
      if (w < 2 || h < 2) return null;
      final stride = p.FPDFBitmap_GetStride(bmp);
      final format = p.FPDFBitmap_GetFormat(bmp);
      final src = p.FPDFBitmap_GetBuffer(bmp).cast<Uint8>().asTypedList(stride * h);
      final bpp = switch (format) { 1 => 1, 2 => 3, _ => 4 };
      var im = img.Image(width: w, height: h, numChannels: 4);
      for (var y = 0; y < h; y++) {
        var s = y * stride;
        for (var x = 0; x < w; x++, s += bpp) {
          if (bpp == 1) {
            im.setPixelRgba(x, y, src[s], src[s], src[s], 255);
          } else {
            im.setPixelRgba(x, y, src[s + 2], src[s + 1], src[s], bpp == 4 && format == 4 ? src[s + 3] : 255);
          }
        }
      }
      if (math.max(w, h) > maxSide) {
        im = w >= h ? img.copyResize(im, width: maxSide) : img.copyResize(im, height: maxSide);
      }
      return (Uint8List.fromList(img.encodePng(im, level: 4)), im.width, im.height);
    } finally {
      p.FPDFBitmap_Destroy(bmp);
    }
  }

  // -------------------------------------------------------------------------
  // Rendering to image files
  // -------------------------------------------------------------------------

  /// Renders an original page to an encoded image at [dpi].
  Uint8List renderEncoded(int pageIndex, {double dpi = 150, RasterFormat format = RasterFormat.png, int quality = 90, bool grayscale = false}) {
    final page = _loadPage(_ref, pageIndex);
    try {
      final r = _renderPage(page, dpi / 72);
      var im = img.Image.fromBytes(width: r.width, height: r.height, bytes: r.rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
      if (grayscale) im = img.grayscale(im);
      final rgb = im.convert(numChannels: 3);
      return Uint8List.fromList(switch (format) {
        RasterFormat.jpg => img.encodeJpg(rgb, quality: quality),
        RasterFormat.png => img.encodePng(rgb, level: 6),
        RasterFormat.tiff => img.encodeTiff(rgb),
      });
    } finally {
      _lib.FPDF_ClosePage(page);
    }
  }

  /// Renders an original page to RGBA (for the reader and comparisons).
  ({Uint8List rgba, int width, int height}) renderOriginal(int pageIndex, double scale) {
    final page = _loadPage(_ref, pageIndex);
    try {
      return _renderPage(page, scale);
    } finally {
      _lib.FPDF_ClosePage(page);
    }
  }

  // -------------------------------------------------------------------------
  // Outline, search, annotations
  // -------------------------------------------------------------------------

  List<PdfOutlineItem> outline() {
    final p = _lib;
    final out = <PdfOutlineItem>[];
    String title(FPDF_BOOKMARK b) {
      final n = p.FPDFBookmark_GetTitle(b, nullptr, 0);
      if (n <= 2) return '';
      final buf = malloc<Uint16>(n ~/ 2);
      try {
        p.FPDFBookmark_GetTitle(b, buf.cast(), n);
        return String.fromCharCodes(buf.asTypedList(n ~/ 2 - 1));
      } finally {
        malloc.free(buf);
      }
    }

    void walk(FPDF_BOOKMARK parent, int level) {
      var child = p.FPDFBookmark_GetFirstChild(_ref, parent);
      final seen = <int>{};
      while (child != nullptr && out.length < 3000 && level < 12) {
        if (!seen.add(child.address)) break; // cyclic outline
        var dest = p.FPDFBookmark_GetDest(_ref, child);
        if (dest == nullptr) {
          final action = p.FPDFBookmark_GetAction(child);
          if (action != nullptr) dest = p.FPDFAction_GetDest(_ref, action);
        }
        final page = dest == nullptr ? -1 : p.FPDFDest_GetDestPageIndex(_ref, dest);
        out.add(PdfOutlineItem(title(child), page < 0 ? null : page, level));
        walk(child, level + 1);
        child = p.FPDFBookmark_GetNextSibling(_ref, child);
      }
    }

    walk(nullptr, 0);
    return out;
  }

  List<PdfSearchHit> search(String query, {int maxHits = 500, bool matchCase = false, bool wholeWord = false}) {
    final p = _lib;
    final q = query.trim();
    if (q.isEmpty) return const [];
    final hits = <PdfSearchHit>[];
    final w = q.toNativeUtf16();
    try {
      for (var i = 0; i < pageCount && hits.length < maxHits; i++) {
        final page = _loadPage(_ref, i);
        final tp = p.FPDFText_LoadPage(page);
        try {
          final g = PdfiumSession._geom(page);
          final h = p.FPDFText_FindStart(tp, w.cast(), (matchCase ? 1 : 0) | (wholeWord ? 2 : 0), 0);
          if (h == nullptr) continue;
          try {
            while (p.FPDFText_FindNext(h) != 0 && hits.length < maxHits) {
              final idx = p.FPDFText_GetSchResultIndex(h), cnt = p.FPDFText_GetSchCount(h);
              final rects = <Rect>[];
              using((a) {
                final l = a<Double>(), t = a<Double>(), r = a<Double>(), b = a<Double>();
                final nr = p.FPDFText_CountRects(tp, idx, cnt);
                for (var k = 0; k < nr; k++) {
                  if (p.FPDFText_GetRect(tp, k, l, t, r, b) != 0) rects.add(g.rectToDisplay(l.value, b.value, r.value, t.value));
                }
              });
              final from = math.max(0, idx - 40);
              final len = math.min(p.FPDFText_CountChars(tp) - from, cnt + 80);
              var ctx = '';
              if (len > 0) {
                final buf = malloc<Uint16>(len + 1);
                try {
                  final got = p.FPDFText_GetText(tp, from, len, buf.cast());
                  ctx = String.fromCharCodes(buf.asTypedList(math.max(0, got - 1))).replaceAll(RegExp(r'\s+'), ' ');
                } finally {
                  malloc.free(buf);
                }
              }
              hits.add(PdfSearchHit(i, rects, ctx));
            }
          } finally {
            p.FPDFText_FindClose(h);
          }
        } finally {
          p.FPDFText_ClosePage(tp);
          p.FPDF_ClosePage(page);
        }
      }
    } finally {
      malloc.free(w);
    }
    return hits;
  }

  String pageText(int pageIndex) {
    final p = _lib;
    final page = _loadPage(_ref, pageIndex);
    final tp = p.FPDFText_LoadPage(page);
    try {
      final n = p.FPDFText_CountChars(tp);
      if (n <= 0) return '';
      final b = malloc<Uint16>(n + 1);
      try {
        final got = p.FPDFText_GetText(tp, 0, n, b.cast());
        return String.fromCharCodes(b.asTypedList(math.max(0, got - 1)));
      } finally {
        malloc.free(b);
      }
    } finally {
      p.FPDFText_ClosePage(tp);
      p.FPDF_ClosePage(page);
    }
  }

  List<PdfAnnotInfo> annotations() {
    final p = _lib;
    final out = <PdfAnnotInfo>[];
    String str(FPDF_ANNOTATION a, String key) {
      final k = key.toNativeUtf8();
      try {
        final n = p.FPDFAnnot_GetStringValue(a, k.cast(), nullptr, 0);
        if (n <= 2) return '';
        final b = malloc<Uint16>(n ~/ 2);
        try {
          p.FPDFAnnot_GetStringValue(a, k.cast(), b.cast(), n);
          return String.fromCharCodes(b.asTypedList(n ~/ 2 - 1));
        } finally {
          malloc.free(b);
        }
      } finally {
        malloc.free(k);
      }
    }

    for (var i = 0; i < pageCount; i++) {
      final page = _loadPage(_ref, i);
      try {
        final g = PdfiumSession._geom(page);
        final n = p.FPDFPage_GetAnnotCount(page);
        for (var k = 0; k < n; k++) {
          final a = p.FPDFPage_GetAnnot(page, k);
          if (a == nullptr) continue;
          try {
            final sub = p.FPDFAnnot_GetSubtype(a);
            if (sub == 16) continue; // popups belong to their parent
            final rect = using((al) {
              final r = al<FS_RECTF>();
              return p.FPDFAnnot_GetRect(a, r) != 0 ? g.rectToDisplay(r.ref.left, r.ref.bottom, r.ref.right, r.ref.top) : Rect.zero;
            });
            out.add(PdfAnnotInfo(i, _annotNames[sub] ?? 'Other', rect, str(a, 'Contents'), str(a, 'T')));
          } finally {
            p.FPDFPage_CloseAnnot(a);
          }
        }
      } finally {
        p.FPDF_ClosePage(page);
      }
    }
    return out;
  }
}
