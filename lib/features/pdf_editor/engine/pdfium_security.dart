part of 'pdfium_engine.dart';

/// An area to redact on a page, in display points.
class RedactArea {
  final Rect rect;
  const RedactArea(this.rect);
}

class RedactOptions {
  final int fillColor; // colour of the box drawn over removed content
  final double rasterDpi; // for pages that must be rasterised
  const RedactOptions({this.fillColor = 0xFF000000, this.rasterDpi = 200});
}

class RedactResult {
  final Uint8List bytes;
  final List<String> report;
  final int charsRemoved;
  final int imagesRedacted;
  final int pathsRemoved;
  final int annotationsRemoved;
  final List<int> rasterizedPages; // 0-based
  final bool verified; // removed text not found in the output
  final List<String> leaks; // removed text still found (should be empty)
  const RedactResult(this.bytes, this.report,
      {this.charsRemoved = 0, this.imagesRedacted = 0, this.pathsRemoved = 0, this.annotationsRemoved = 0, this.rasterizedPages = const [], this.verified = false, this.leaks = const []});
}

class ImageOptimizeOptions {
  final double maxDpi; // images above this effective resolution are downsampled
  final int quality; // JPEG quality for recompressed images
  final bool grayscale;
  const ImageOptimizeOptions({this.maxDpi = 150, this.quality = 75, this.grayscale = false});
}

class OptimizeResult {
  final Uint8List bytes;
  final int imagesRecompressed;
  final int imagesSkipped; // transparent or already small
  final int originalSize;
  const OptimizeResult(this.bytes, this.imagesRecompressed, this.imagesSkipped, this.originalSize);
}

enum PagePattern { blank, lined, grid, dotted }

class PatternPage {
  final int insertAt; // index in the output document
  final PagePattern pattern;
  final Size size;
  final double spacing; // points between lines/dots
  const PatternPage(this.insertAt, this.pattern, {this.size = const Size(595.28, 841.89), this.spacing = 22});
}

class _Ch {
  final int code;
  final Rect box;
  final double ox, oy; // origin in user space
  bool removed = false;
  _Ch(this.code, this.box, this.ox, this.oy);
}

extension PdfiumSecurity on PdfiumSession {
  PDFium get _lib2 => PdfiumSession._p;

  /// True redaction: removes text characters, image pixels, vector paths
  /// and annotations inside [areas] from the content (not just covering
  /// them), then rebuilds the document into a new file so no orphaned
  /// objects, old revisions, metadata, bookmarks or attachments survive.
  /// Pages whose content cannot be edited precisely are rasterised.
  RedactResult redact(Map<int, List<RedactArea>> areas, {RedactOptions options = const RedactOptions()}) {
    final p = _lib2;
    final doc = _loadCopy();
    final report = <String>[];
    final removedText = <int, List<String>>{};
    var chars = 0, images = 0, paths = 0, annots = 0;
    final raster = <int>[];
    try {
      for (final entry in areas.entries) {
        final pi = entry.key;
        if (pi < 0 || pi >= p.FPDF_GetPageCount(doc)) continue;
        final rects = entry.value.map((a) => a.rect).where((r) => r.width > 0 && r.height > 0).toList();
        if (rects.isEmpty) continue;
        final page = _loadPage(doc, pi);
        var fallback = false;
        try {
          final g = PdfiumSession._geom(page);
          bool hit(Rect r) => rects.any((a) {
                final i = a.intersect(r);
                return i.width > 0 && i.height > 0 && (i.width * i.height >= r.width * r.height * 0.3 || a.contains(r.center));
              });
          // 1. Characters per text object.
          final byObj = <int, List<_Ch>>{};
          final tp = p.FPDFText_LoadPage(page);
          using((a) {
            final l = a<Double>(), r = a<Double>(), b = a<Double>(), t = a<Double>(), ox = a<Double>(), oy = a<Double>();
            final n = p.FPDFText_CountChars(tp);
            for (var i = 0; i < n; i++) {
              final obj = p.FPDFText_GetTextObject(tp, i);
              if (obj == nullptr) continue;
              final u = p.FPDFText_GetUnicode(tp, i);
              if (p.FPDFText_GetCharBox(tp, i, l, r, b, t) == 0) continue;
              p.FPDFText_GetCharOrigin(tp, i, ox, oy);
              final ch = _Ch(u, g.rectToDisplay(l.value, b.value, r.value, t.value), ox.value, oy.value);
              ch.removed = u > 0x20 && hit(ch.box);
              byObj.putIfAbsent(obj.address, () => []).add(ch);
            }
          });
          p.FPDFText_ClosePage(tp);
          final count = p.FPDFPage_CountObjects(page);
          final objs = [for (var i = 0; i < count; i++) p.FPDFPage_GetObject(page, i)];
          final remove = <FPDF_PAGEOBJECT>[];
          final insert = <FPDF_PAGEOBJECT>[];
          for (final o in objs) {
            final type = p.FPDFPageObj_GetType(o);
            final bounds = PdfiumSession._objBounds(o, g);
            if (!rects.any((a) => a.overlaps(bounds))) continue;
            if (type == FPDF_PAGEOBJ_TEXT) {
              final cs = byObj[o.address] ?? const <_Ch>[];
              if (!cs.any((c) => c.removed)) {
                if (cs.isEmpty && rects.any((a) => a.overlaps(bounds))) {
                  // Text PDFium could not map to characters: cannot redact precisely.
                  fallback = true;
                }
                continue;
              }
              final removedStr = String.fromCharCodes(cs.where((c) => c.removed).map((c) => c.code)).trim();
              if (removedStr.isNotEmpty) removedText.putIfAbsent(pi, () => []).add(removedStr);
              chars += cs.where((c) => c.removed).length;
              // Re-create the surviving words in the original font.
              final font = p.FPDFTextObj_GetFont(o);
              final size = using((a) {
                final v = a<Float>();
                return p.FPDFTextObj_GetFontSize(o, v) != 0 ? v.value.toDouble() : 0.0;
              });
              final m = PdfiumSession._matrix(o);
              final color = PdfiumSession._fillColor(o);
              final mode = p.FPDFTextObj_GetTextRenderMode(o);
              final groups = <List<_Ch>>[];
              var cur = <_Ch>[];
              for (final c in cs) {
                final breakHere = c.removed || c.code <= 0x20 || (cur.isNotEmpty && (c.box.left - cur.last.box.right) > size * 0.3);
                if (breakHere) {
                  if (cur.isNotEmpty) groups.add(cur);
                  cur = [];
                }
                if (!c.removed && c.code > 0x20) cur.add(c);
              }
              if (cur.isNotEmpty) groups.add(cur);
              var ok = true;
              final created = <FPDF_PAGEOBJECT>[];
              for (final gr in groups) {
                final text = String.fromCharCodes(gr.map((c) => c.code));
                if (!PdfiumSession.fontCovers(font, text)) {
                  ok = false;
                  break;
                }
                final no = p.FPDFPageObj_CreateTextObj(doc, font, size);
                if (no == nullptr) {
                  ok = false;
                  break;
                }
                PdfiumSession._setText(no, text);
                PdfiumSession._setMatrix(no, [m[0], m[1], m[2], m[3], gr.first.ox, gr.first.oy]);
                PdfiumSession._setFill(no, color);
                p.FPDFTextObj_SetTextRenderMode(no, mode);
                created.add(no);
              }
              if (!ok) {
                for (final c in created) {
                  p.FPDFPageObj_Destroy(c);
                }
                fallback = true;
                continue;
              }
              insert.addAll(created);
              remove.add(o);
            } else if (type == FPDF_PAGEOBJ_IMAGE) {
              if (_redactImage(page, o, g, rects)) {
                images++;
              } else {
                fallback = true;
              }
            } else if (type == FPDF_PAGEOBJ_PATH) {
              if (rects.any((a) => a.inflate(1).contains(bounds.topLeft) && a.inflate(1).contains(bounds.bottomRight))) {
                remove.add(o);
                paths++;
              }
            } else if (type == FPDF_PAGEOBJ_FORM || type == FPDF_PAGEOBJ_SHADING) {
              // Nested content cannot be edited here; rasterise the page.
              fallback = true;
            }
          }
          for (final o in remove) {
            if (p.FPDFPage_RemoveObject(page, o) != 0) p.FPDFPageObj_Destroy(o);
          }
          for (final o in insert) {
            p.FPDFPage_InsertObject(page, o);
          }
          // 2. Annotations (comments, links, form widgets) in the areas.
          for (var k = p.FPDFPage_GetAnnotCount(page) - 1; k >= 0; k--) {
            final an = p.FPDFPage_GetAnnot(page, k);
            if (an == nullptr) continue;
            final r = using((a) {
              final fr = a<FS_RECTF>();
              return p.FPDFAnnot_GetRect(an, fr) != 0 ? g.rectToDisplay(fr.ref.left, fr.ref.bottom, fr.ref.right, fr.ref.top) : Rect.zero;
            });
            p.FPDFPage_CloseAnnot(an);
            if (rects.any((a) => a.overlaps(r))) {
              if (p.FPDFPage_RemoveAnnot(page, k) != 0) annots++;
            }
          }
          // 3. Visible redaction boxes.
          for (final a in rects) {
            final (l, b, r, t) = g.rectToUser(a);
            final box = p.FPDFPageObj_CreateNewRect(l, b, r - l, t - b);
            PdfiumSession._setFill(box, options.fillColor);
            p.FPDFPath_SetDrawMode(box, FPDF_FILLMODE_WINDING, 0);
            p.FPDFPage_InsertObject(page, box);
          }
          p.FPDFPage_GenerateContent(page);
          if (fallback) {
            _rasterizePage(doc, page, rects, options);
            raster.add(pi);
          }
        } finally {
          p.FPDF_ClosePage(page);
        }
      }
      // 4. Flatten what is left (form widgets, comments) so the copy is
      // static, and write inheritable page attributes onto each page so the
      // import below keeps page sizes and rotation.
      for (var i = 0; i < p.FPDF_GetPageCount(doc); i++) {
        final page = _loadPage(doc, i);
        using((a) {
          final l = a<Float>(), b = a<Float>(), r = a<Float>(), t = a<Float>();
          if (p.FPDFPage_GetMediaBox(page, l, b, r, t) != 0) {
            p.FPDFPage_SetMediaBox(page, l.value, b.value, r.value, t.value);
          } else {
            p.FPDFPage_SetMediaBox(page, 0, 0, p.FPDF_GetPageWidthF(page), p.FPDF_GetPageHeightF(page));
          }
          if (p.FPDFPage_GetCropBox(page, l, b, r, t) != 0) p.FPDFPage_SetCropBox(page, l.value, b.value, r.value, t.value);
        });
        p.FPDFPage_SetRotation(page, p.FPDFPage_GetRotation(page));
        _renderTiny(page);
        p.FPDFPage_Flatten(page, FLAT_PRINT);
        p.FPDF_ClosePage(page);
      }
      // 5. Rebuild into a new document: only reachable page content is copied.
      final clean = p.FPDF_CreateNewDocument();
      try {
        if (p.FPDF_ImportPagesByIndex(clean, doc, nullptr, 0, 0) == 0) throw const PdfEditException('Redacted pages could not be copied.');
        final bytes = _save(clean, FPDF_NO_INCREMENTAL);
        // 6. Verify: removed text must not be found anywhere in the output.
        final leaks = <String>[];
        final texts = PdfiumSession.pageTexts(bytes);
        final raw = latin1.decode(bytes, allowInvalid: true);
        for (final e in removedText.entries) {
          for (final s in e.value) {
            for (final word in s.split(RegExp(r'\s+')).where((w) => w.length >= 3)) {
              final inText = e.key < texts.length && texts[e.key].contains(word);
              if (inText || raw.contains(word)) leaks.add(word);
            }
          }
        }
        report.add('$chars character(s) of text removed from the page content.');
        if (images > 0) report.add('$images image(s) had the redacted pixels overwritten.');
        if (paths > 0) report.add('$paths vector shape(s) inside the areas removed.');
        if (annots > 0) report.add('$annots annotation(s), link(s) or form field(s) in the areas removed.');
        if (raster.isNotEmpty) {
          report.add('Pages ${raster.map((e) => e + 1).join(', ')} contained content that cannot be edited precisely and were converted to images (their text is no longer selectable).');
        }
        report.add('The copy was rebuilt from the page content only: document metadata, bookmarks, attachments, form fields and earlier revisions are not included; remaining annotations were flattened.');
        report.add(leaks.isEmpty ? 'Verified: none of the removed text appears in the output file.' : 'WARNING: some removed text was still found: ${leaks.toSet().join(', ')}');
        return RedactResult(bytes, report,
            charsRemoved: chars, imagesRedacted: images, pathsRemoved: paths, annotationsRemoved: annots, rasterizedPages: raster, verified: leaks.isEmpty, leaks: leaks);
      } finally {
        p.FPDF_CloseDocument(clean);
      }
    } finally {
      p.FPDF_CloseDocument(doc);
    }
  }

  /// Overwrites the redacted pixels of an image (in the image's own pixel
  /// space). Returns false when the image cannot be processed.
  bool _redactImage(FPDF_PAGE page, FPDF_PAGEOBJECT o, _Geom g, List<Rect> rects) {
    final p = _lib2;
    final bmp = p.FPDFImageObj_GetBitmap(o);
    if (bmp == nullptr) return false;
    try {
      final w = p.FPDFBitmap_GetWidth(bmp), h = p.FPDFBitmap_GetHeight(bmp);
      if (w * h > 40000000) return false;
      final stride = p.FPDFBitmap_GetStride(bmp);
      final format = p.FPDFBitmap_GetFormat(bmp);
      final bpp = switch (format) { 1 => 1, 2 => 3, _ => 4 };
      final src = p.FPDFBitmap_GetBuffer(bmp).cast<Uint8>().asTypedList(stride * h);
      final buf = malloc<Uint8>(w * h * 4);
      try {
        final out = buf.asTypedList(w * h * 4);
        for (var y = 0; y < h; y++) {
          var s = y * stride, d = y * w * 4;
          for (var x = 0; x < w; x++, s += bpp, d += 4) {
            if (bpp == 1) {
              out[d] = out[d + 1] = out[d + 2] = src[s];
            } else {
              out[d] = src[s];
              out[d + 1] = src[s + 1];
              out[d + 2] = src[s + 2];
            }
            out[d + 3] = 255;
          }
        }
        // Inverse of the image matrix: user space → unit square.
        final m = PdfiumSession._matrix(o);
        final det = m[0] * m[3] - m[1] * m[2];
        if (det.abs() < 1e-9) return false;
        (double, double) toUnit(double x, double y) {
          final dx = x - m[4], dy = y - m[5];
          return ((m[3] * dx - m[2] * dy) / det, (-m[1] * dx + m[0] * dy) / det);
        }

        for (final a in rects) {
          final (l, b, r, t) = g.rectToUser(a);
          final corners = [toUnit(l, b), toUnit(r, b), toUnit(l, t), toUnit(r, t)];
          final us = corners.map((c) => c.$1), vs = corners.map((c) => c.$2);
          final x0 = (us.reduce(math.min) * w).floor().clamp(0, w), x1 = (us.reduce(math.max) * w).ceil().clamp(0, w);
          final y0 = ((1 - vs.reduce(math.max)) * h).floor().clamp(0, h), y1 = ((1 - vs.reduce(math.min)) * h).ceil().clamp(0, h);
          for (var y = y0; y < y1; y++) {
            for (var x = x0; x < x1; x++) {
              final d = (y * w + x) * 4;
              out[d] = out[d + 1] = out[d + 2] = 0;
            }
          }
        }
        final nb = p.FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA, buf.cast(), w * 4);
        final pages = malloc<FPDF_PAGE>();
        try {
          pages.value = page;
          return p.FPDFImageObj_SetBitmap(pages, 1, o, nb) != 0;
        } finally {
          malloc.free(pages);
          p.FPDFBitmap_Destroy(nb);
        }
      } finally {
        malloc.free(buf);
      }
    } finally {
      p.FPDFBitmap_Destroy(bmp);
    }
  }

  /// Replaces a page's content with a picture of it, the areas painted over.
  void _rasterizePage(FPDF_DOCUMENT doc, FPDF_PAGE page, List<Rect> rects, RedactOptions o) {
    final p = _lib2;
    final scale = o.rasterDpi / 72;
    final r = _renderPage(page, scale);
    final g = PdfiumSession._geom(page);
    final rgba = r.rgba;
    final col = o.fillColor;
    for (final a in rects) {
      final x0 = (a.left * scale).floor().clamp(0, r.width), x1 = (a.right * scale).ceil().clamp(0, r.width);
      final y0 = (a.top * scale).floor().clamp(0, r.height), y1 = (a.bottom * scale).ceil().clamp(0, r.height);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final d = (y * r.width + x) * 4;
          rgba[d] = (col >> 16) & 0xFF;
          rgba[d + 1] = (col >> 8) & 0xFF;
          rgba[d + 2] = col & 0xFF;
        }
      }
    }
    for (var i = p.FPDFPage_CountObjects(page) - 1; i >= 0; i--) {
      final o2 = p.FPDFPage_GetObject(page, i);
      if (p.FPDFPage_RemoveObject(page, o2) != 0) p.FPDFPageObj_Destroy(o2);
    }
    for (var k = p.FPDFPage_GetAnnotCount(page) - 1; k >= 0; k--) {
      p.FPDFPage_RemoveAnnot(page, k);
    }
    final im = img.Image.fromBytes(width: r.width, height: r.height, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba).convert(numChannels: 3);
    final jpeg = Uint8List.fromList(img.encodeJpg(im, quality: 88));
    final obj = p.FPDFPageObj_NewImageObj(doc);
    final pages = malloc<FPDF_PAGE>();
    try {
      pages.value = page;
      _loadJpeg(pages, obj, jpeg);
    } finally {
      malloc.free(pages);
    }
    final size = g.display;
    PdfiumSession._setMatrix(obj, g.frame(Offset(0, size.height), Offset(size.width, 0), Offset(0, -size.height)));
    p.FPDFPage_InsertObject(page, obj);
    p.FPDFPage_GenerateContent(page);
  }

  /// Recompresses large images as JPEG. Text, vector graphics, links, form
  /// fields, annotations and bookmarks are untouched. Images with
  /// transparency are skipped (JPEG has no alpha).
  OptimizeResult optimizeImages(ImageOptimizeOptions o) {
    final p = _lib2;
    final doc = _loadCopy();
    var done = 0, skipped = 0;
    try {
      for (var i = 0; i < p.FPDF_GetPageCount(doc); i++) {
        final page = _loadPage(doc, i);
        try {
          final g = PdfiumSession._geom(page);
          final pages = malloc<FPDF_PAGE>();
          pages.value = page;
          try {
            for (var k = 0; k < p.FPDFPage_CountObjects(page); k++) {
              final obj = p.FPDFPage_GetObject(page, k);
              if (p.FPDFPageObj_GetType(obj) != FPDF_PAGEOBJ_IMAGE) continue;
              if (p.FPDFPageObj_HasTransparency(obj) != 0) {
                skipped++;
                continue;
              }
              final bounds = PdfiumSession._objBounds(obj, g);
              final rawLen = p.FPDFImageObj_GetImageDataRaw(obj, nullptr, 0);
              final bmp = p.FPDFImageObj_GetBitmap(obj);
              if (bmp == nullptr || bounds.width <= 0) {
                skipped++;
                continue;
              }
              Uint8List? jpeg;
              try {
                final w = p.FPDFBitmap_GetWidth(bmp), h = p.FPDFBitmap_GetHeight(bmp);
                final stride = p.FPDFBitmap_GetStride(bmp);
                final format = p.FPDFBitmap_GetFormat(bmp);
                final bpp = switch (format) { 1 => 1, 2 => 3, _ => 4 };
                final src = p.FPDFBitmap_GetBuffer(bmp).cast<Uint8>().asTypedList(stride * h);
                var im = img.Image(width: w, height: h);
                for (var y = 0; y < h; y++) {
                  var s = y * stride;
                  for (var x = 0; x < w; x++, s += bpp) {
                    if (bpp == 1) {
                      im.setPixelRgb(x, y, src[s], src[s], src[s]);
                    } else {
                      im.setPixelRgb(x, y, src[s + 2], src[s + 1], src[s]);
                    }
                  }
                }
                final dpi = w / (bounds.width / 72);
                if (dpi > o.maxDpi * 1.05) {
                  final nw = math.max(1, (w * o.maxDpi / dpi).round());
                  im = img.copyResize(im, width: nw, interpolation: img.Interpolation.average);
                }
                if (o.grayscale) im = img.grayscale(im);
                jpeg = Uint8List.fromList(img.encodeJpg(im, quality: o.quality));
              } finally {
                p.FPDFBitmap_Destroy(bmp);
              }
              if (jpeg.length < rawLen * 0.9 || o.grayscale) {
                final m = PdfiumSession._matrix(obj);
                if (_loadJpeg(pages, obj, jpeg)) {
                  PdfiumSession._setMatrix(obj, m);
                  done++;
                } else {
                  skipped++;
                }
              } else {
                skipped++;
              }
            }
          } finally {
            malloc.free(pages);
          }
          p.FPDFPage_GenerateContent(page);
        } finally {
          p.FPDF_ClosePage(page);
        }
      }
      final bytes = _save(doc, FPDF_NO_INCREMENTAL);
      return OptimizeResult(bytes, done, skipped, _len);
    } finally {
      p.FPDF_CloseDocument(doc);
    }
  }

  /// Inserts blank, lined, grid or dotted pages.
  Uint8List insertPatternPages(List<PatternPage> pagesToAdd) {
    final p = _lib2;
    final doc = _loadCopy();
    try {
      for (final spec in [...pagesToAdd]..sort((a, b) => a.insertAt.compareTo(b.insertAt))) {
        final at = spec.insertAt.clamp(0, p.FPDF_GetPageCount(doc));
        final page = p.FPDFPage_New(doc, at, spec.size.width, spec.size.height);
        try {
          final w = spec.size.width, h = spec.size.height, s = spec.spacing;
          void line(double x0, double y0, double x1, double y1) {
            final path = p.FPDFPageObj_CreateNewPath(x0, y0);
            p.FPDFPath_LineTo(path, x1, y1);
            p.FPDFPageObj_SetStrokeColor(path, 170, 190, 215, 255);
            p.FPDFPageObj_SetStrokeWidth(path, 0.6);
            p.FPDFPath_SetDrawMode(path, FPDF_FILLMODE_NONE, 1);
            p.FPDFPage_InsertObject(page, path);
          }

          switch (spec.pattern) {
            case PagePattern.lined:
              for (var y = h - 72.0; y > 36; y -= s) {
                line(36, y, w - 36, y);
              }
            case PagePattern.grid:
              for (var y = h - 36.0; y > 36; y -= s) {
                line(36, y, w - 36, y);
              }
              for (var x = 36.0; x < w - 36; x += s) {
                line(x, 36, x, h - 36);
              }
            case PagePattern.dotted:
              for (var y = h - 36.0; y > 36; y -= s) {
                for (var x = 36.0; x < w - 36; x += s) {
                  final dot = p.FPDFPageObj_CreateNewRect(x - 0.6, y - 0.6, 1.2, 1.2);
                  p.FPDFPageObj_SetFillColor(dot, 150, 150, 150, 255);
                  p.FPDFPath_SetDrawMode(dot, FPDF_FILLMODE_WINDING, 0);
                  p.FPDFPage_InsertObject(page, dot);
                }
              }
            case PagePattern.blank:
              break;
          }
          p.FPDFPage_GenerateContent(page);
        } finally {
          p.FPDF_ClosePage(page);
        }
      }
      return _save(doc, FPDF_NO_INCREMENTAL);
    } finally {
      p.FPDF_CloseDocument(doc);
    }
  }

  /// Replaces pages: target page index → page index in [otherBytes].
  Uint8List replacePages(Uint8List otherBytes, String? otherPassword, Map<int, int> mapping) {
    final p = _lib2;
    final doc = _loadCopy();
    final buf = malloc<Uint8>(otherBytes.length);
    buf.asTypedList(otherBytes.length).setAll(0, otherBytes);
    final other = PdfiumSession._load(buf, otherBytes.length, otherPassword);
    try {
      if (other == nullptr) throw const PdfEditException('The replacement PDF could not be opened.');
      final n = p.FPDF_GetPageCount(other);
      for (final e in mapping.entries.toList()..sort((a, b) => b.key.compareTo(a.key))) {
        if (e.key < 0 || e.key >= p.FPDF_GetPageCount(doc) || e.value < 0 || e.value >= n) throw const PdfEditException('Page number out of range.');
        p.FPDFPage_Delete(doc, e.key);
        final idx = malloc<Int>();
        try {
          idx.value = e.value;
          if (p.FPDF_ImportPagesByIndex(doc, other, idx, 1, e.key) == 0) throw const PdfEditException('The page could not be imported.');
        } finally {
          malloc.free(idx);
        }
      }
      return _save(doc, encrypted ? FPDF_NO_INCREMENTAL : FPDF_NO_INCREMENTAL);
    } finally {
      if (other != nullptr) p.FPDF_CloseDocument(other);
      malloc.free(buf);
      p.FPDF_CloseDocument(doc);
    }
  }
}
