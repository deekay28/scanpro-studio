import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'model/doc_model.dart';
import 'ooxml/pptx.dart';

/// True when standard PDF fonts can draw [s]. Syncfusion's standard fonts
/// only encode Latin-1, so the Windows-1252 extras (— € “ ”) go to the
/// embedded Unicode font.
bool isWinAnsi(String s) {
  for (final r in s.runes) {
    if (r < 0x20 && r != 0x09 && r != 0x0a && r != 0x0d) return false;
    if (r <= 0x7e || (r >= 0xa0 && r <= 0xff)) continue;
    return false;
  }
  return true;
}

/// Font cache for one output document.
class PdfFonts {
  final Uint8List unicodeFont;
  final Map<String, sf.PdfFont> _cache = {};
  PdfFonts(this.unicodeFont);

  sf.PdfFont get(String? family, double size, {bool bold = false, bool italic = false, String text = ''}) {
    final s = double.parse(size.clamp(2, 300).toStringAsFixed(1));
    if (!isWinAnsi(text)) {
      return _cache.putIfAbsent('u$s', () => sf.PdfTrueTypeFont(unicodeFont, s));
    }
    final f = (family ?? '').toLowerCase();
    final fam = RegExp('times|serif|georgia|garamond|cambria|book|roman|palatino').hasMatch(f) && !f.contains('sans')
        ? sf.PdfFontFamily.timesRoman
        : RegExp('courier|mono|consol|code').hasMatch(f)
            ? sf.PdfFontFamily.courier
            : sf.PdfFontFamily.helvetica;
    return _cache.putIfAbsent('${fam.name}$s$bold$italic', () {
      if (bold && italic) return sf.PdfStandardFont(fam, s, multiStyle: const [sf.PdfFontStyle.bold, sf.PdfFontStyle.italic]);
      return sf.PdfStandardFont(fam, s, style: bold ? sf.PdfFontStyle.bold : (italic ? sf.PdfFontStyle.italic : sf.PdfFontStyle.regular));
    });
  }
}

sf.PdfColor _c(int argb) => sf.PdfColor((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);

void _setSize(sf.PdfPageSettings s, Size size) {
  s.orientation = size.width > size.height ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;
  s.size = size;
}

class _Token {
  final String text;
  final DocRun run;
  final sf.PdfFont font;
  final double width;
  final bool space;
  final bool newline;
  _Token(this.text, this.run, this.font, this.width, {this.space = false, this.newline = false});
}

/// Lays out a [DocModel] into a PDF (flowing text with mixed formatting,
/// lists, tables, images, page breaks, header/footer and links).
class DocPdfRenderer {
  final PdfFonts fonts;
  DocPdfRenderer(Uint8List unicodeFont) : fonts = PdfFonts(unicodeFont);

  late sf.PdfDocument _doc;
  late sf.PdfPage _page;
  late Size _size;
  late double _margin;
  late double _y;

  void _newPage(Size size) {
    final section = _doc.sections!.add();
    section.pageSettings.margins.all = 0;
    _setSize(section.pageSettings, size);
    _page = section.pages.add();
    _size = size;
    _y = _margin;
  }

  Uint8List render(DocModel m) {
    _doc = sf.PdfDocument();
    try {
      _doc.pageSettings.margins.all = 0;
      _doc.documentInformation
        ..title = m.title
        ..creator = 'ScanPro Studio';
      _margin = m.margin;
      Size? nextSize;
      for (final b in m.blocks) {
        if (b is DocPageBreak && b.pageWidth != null) {
          nextSize = Size(b.pageWidth!, b.pageHeight!);
          break;
        }
      }
      _newPage(nextSize ?? Size(m.pageWidth, m.pageHeight));
      var number = 0;
      for (final b in m.blocks) {
        switch (b) {
          case DocParagraph p:
            if (p.style == ParaStyle.numbered) {
              number++;
            } else {
              number = 0;
            }
            _paragraph(p, number);
          case DocTable t:
            number = 0;
            _table(t);
          case DocImage img:
            _image(img);
          case DocPageBreak _:
            number = 0;
            // The size of the next page: the next section break's size.
            final idx = m.blocks.indexOf(b);
            Size? size;
            for (final n in m.blocks.skip(idx + 1)) {
              if (n is DocPageBreak && n.pageWidth != null) {
                size = Size(n.pageWidth!, n.pageHeight!);
                break;
              }
            }
            _newPage(size ?? Size(m.pageWidth, m.pageHeight));
        }
      }
      if (m.header.isNotEmpty || m.footer.isNotEmpty) {
        for (var i = 0; i < _doc.pages.count; i++) {
          final pg = _doc.pages[i];
          final sz = pg.size;
          final f = fonts.get(null, 9, text: '${m.header}${m.footer}');
          final fmt = sf.PdfStringFormat(alignment: sf.PdfTextAlignment.center);
          if (m.header.isNotEmpty) pg.graphics.drawString(m.header, f, brush: sf.PdfBrushes.gray, bounds: Rect.fromLTWH(_margin, _margin / 3, sz.width - 2 * _margin, 14), format: fmt);
          if (m.footer.isNotEmpty) pg.graphics.drawString(m.footer, f, brush: sf.PdfBrushes.gray, bounds: Rect.fromLTWH(_margin, sz.height - _margin / 2 - 8, sz.width - 2 * _margin, 14), format: fmt);
        }
      }
      return Uint8List.fromList(_doc.saveSync());
    } finally {
      _doc.dispose();
    }
  }

  final Map<sf.PdfFont, double> _spaces = {};

  /// Width of a space (measureString trims whitespace, so it is derived).
  double _spaceWidth(sf.PdfFont f) => _spaces.putIfAbsent(f, () => math.max(f.size * 0.2, f.measureString('a a').width - f.measureString('aa').width));

  double _defaultSize(ParaStyle s) => switch (s) { ParaStyle.title => 24, ParaStyle.h1 => 18, ParaStyle.h2 => 15, ParaStyle.h3 => 12.5, _ => 11 };

  void _paragraph(DocParagraph p, int number) {
    final base = _defaultSize(p.style);
    final heading = p.style == ParaStyle.title || p.style == ParaStyle.h1 || p.style == ParaStyle.h2 || p.style == ParaStyle.h3;
    final list = p.style == ParaStyle.bullet || p.style == ParaStyle.numbered;
    final left = _margin + p.indentLeft + (list ? 18.0 + 18 * p.listLevel : 0);
    final width = _size.width - _margin - left;
    _y += p.spaceBefore > 0 ? p.spaceBefore : (heading ? base * 0.6 : 0);
    // Tokens.
    final tokens = <_Token>[];
    for (final r in p.runs) {
      final size = r.size ?? base;
      // One font per run keeps a consistent baseline within the run.
      final font = fonts.get(r.font, size, bold: r.bold || heading, italic: r.italic, text: r.text);
      for (final m in RegExp(r'\n|\t| +|[^ \t\n]+').allMatches(r.text)) {
        final t = m.group(0)!;
        if (t == '\n') {
          tokens.add(_Token('', r, font, 0, newline: true));
        } else if (t == '\t') {
          tokens.add(_Token(' ', r, font, 36, space: true));
        } else if (t.trim().isEmpty) {
          tokens.add(_Token(' ' * t.length, r, font, _spaceWidth(font) * t.length, space: true));
        } else {
          tokens.add(_Token(t, r, font, font.measureString(t).width));
        }
      }
    }
    if (tokens.isEmpty) {
      _y += base * 1.2;
      return;
    }
    // Lines.
    final lines = <List<_Token>>[];
    var cur = <_Token>[];
    var w = 0.0;
    for (final t in tokens) {
      if (t.newline) {
        lines.add(cur);
        cur = [];
        w = 0;
        continue;
      }
      if (!t.space && w + t.width > width && cur.any((e) => !e.space)) {
        while (cur.isNotEmpty && cur.last.space) {
          cur.removeLast();
        }
        lines.add(cur);
        cur = [];
        w = 0;
      }
      if (cur.isEmpty && t.space) continue;
      cur.add(t);
      w += t.width;
    }
    lines.add(cur);
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final h = line.isEmpty ? base * 1.25 : line.map((t) => t.font.height).reduce(math.max) * 1.18;
      if (_y + h > _size.height - _margin && _y > _margin + 1) _newPage(_size);
      final lw = line.fold<double>(0, (a, t) => a + t.width);
      var x = left;
      var extra = 0.0;
      final spaces = line.where((t) => t.space).length;
      switch (p.align) {
        case ParaAlign.center:
          x += (width - lw) / 2;
        case ParaAlign.right:
          x += width - lw;
        case ParaAlign.justify:
          if (li < lines.length - 1 && spaces > 0) extra = (width - lw) / spaces;
        case ParaAlign.left:
          break;
      }
      if (li == 0 && list) {
        final marker = p.style == ParaStyle.bullet ? '•' : '$number.';
        final mf = fonts.get(null, line.isEmpty ? base : line.first.font.size, text: marker);
        _page.graphics.drawString(marker, mf, brush: sf.PdfBrushes.black, bounds: Rect.fromLTWH(left - 14, _y, 0, 0));
      }
      final baseline = h / 1.18;
      // Consecutive tokens of the same run are drawn as one string with
      // real spaces, so copied or extracted text keeps its word breaks.
      // Justified lines are drawn word by word.
      var i = 0;
      while (i < line.length) {
        final t = line[i];
        if (t.space) {
          x += t.width + extra;
          i++;
          continue;
        }
        var j = i + 1;
        var text = t.text;
        var width = t.width;
        if (extra == 0) {
          while (j < line.length && identical(line[j].run, t.run) && identical(line[j].font, t.font)) {
            final n = line[j];
            if (n.space && (j + 1 >= line.length || !identical(line[j + 1].run, t.run) || line[j + 1].space)) break;
            text += n.text;
            width += n.width;
            j++;
          }
        }
        final color = t.run.color ?? 0xFF000000;
        final brush = sf.PdfSolidBrush(_c(t.run.link != null && t.run.color == null ? 0xFF0563C1 : color));
        final top = _y + baseline - t.font.height;
        _page.graphics.drawString(text, t.font, brush: brush, bounds: Rect.fromLTWH(x, top, 0, 0));
        if (t.run.underline || t.run.link != null) {
          _page.graphics.drawLine(sf.PdfPen(_c(color), width: 0.6), Offset(x, _y + baseline + 1), Offset(x + width, _y + baseline + 1));
        }
        if (t.run.link != null) {
          _page.annotations.add(sf.PdfUriAnnotation(bounds: Rect.fromLTWH(x, top, width, t.font.height), uri: t.run.link!));
        }
        x += width;
        i = j;
      }
      _y += h;
    }
    _y += heading ? base * 0.3 : base * 0.45;
  }

  void _table(DocTable t) {
    final cols = t.columnCount;
    if (cols == 0 || t.rows.isEmpty) return;
    final allText = t.rows.expand((r) => r).map((c) => c.text).join();
    final width = _size.width - 2 * _margin;
    final size = cols > 8 ? 7.0 : (cols > 5 ? 8.5 : 10.0);
    final font = fonts.get(null, size, text: allText);
    final grid = sf.PdfGrid();
    grid.columns.add(count: cols);
    grid.style = sf.PdfGridStyle(font: font, cellPadding: sf.PdfPaddings(left: 3, right: 3, top: 2, bottom: 2));
    var start = 0;
    if (t.headerRow) {
      grid.headers.add(1);
      final h = grid.headers[0];
      for (var c = 0; c < cols; c++) {
        h.cells[c].value = c < t.rows[0].length ? t.rows[0][c].text : '';
      }
      h.style = sf.PdfGridRowStyle(backgroundBrush: sf.PdfSolidBrush(sf.PdfColor(230, 230, 230)), font: fonts.get(null, size, bold: true, text: allText));
      start = 1;
    }
    for (var r = start; r < t.rows.length; r++) {
      final row = grid.rows.add();
      for (var c = 0; c < cols; c++) {
        final cell = c < t.rows[r].length ? t.rows[r][c] : const DocTableCell('');
        row.cells[c].value = cell.text;
        if (cell.number != null) row.cells[c].stringFormat = sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right);
      }
    }
    if (_y > _size.height - _margin - 40) _newPage(_size);
    final res = grid.draw(page: _page, bounds: Rect.fromLTWH(_margin, _y, width, 0), format: sf.PdfLayoutFormat(layoutType: sf.PdfLayoutType.paginate));
    if (res != null) {
      _page = res.page;
      _y = res.bounds.bottom + 10;
    }
  }

  void _image(DocImage img) {
    final bmp = sf.PdfBitmap(img.bytes);
    if (img.x != null && img.y != null) {
      _page.graphics.drawImage(bmp, Rect.fromLTWH(img.x!, img.y!, img.width, img.height));
      return;
    }
    final maxW = _size.width - 2 * _margin;
    final maxH = _size.height - 2 * _margin;
    var w = img.width, h = img.height;
    final k = math.min(1.0, math.min(maxW / w, maxH / h));
    w *= k;
    h *= k;
    if (_y + h > _size.height - _margin) _newPage(_size);
    _page.graphics.drawImage(bmp, Rect.fromLTWH(_margin, _y, w, h));
    _y += h + 8;
  }
}

/// Renders slides as PDF pages at their positions. Charts are drawn from
/// their stored values; a chart without stored values is shown as a labelled
/// placeholder (values are never invented).
Uint8List slidesToPdf(PresentationModel deck, Uint8List unicodeFont, {List<int>? only}) {
  final fonts = PdfFonts(unicodeFont);
  final doc = sf.PdfDocument();
  try {
    doc.pageSettings.margins.all = 0;
    doc.documentInformation
      ..title = deck.title
      ..creator = 'ScanPro Studio';
    final size = Size(deck.width, deck.height);
    for (var i = 0; i < deck.slides.length; i++) {
      if (only != null && !only.contains(i)) continue;
      final section = doc.sections!.add();
      section.pageSettings.margins.all = 0;
      _setSize(section.pageSettings, size);
      final g = section.pages.add().graphics;
      for (final s in deck.slides[i].shapes) {
        switch (s) {
          case SlidePicture p:
            try {
              g.drawImage(sf.PdfBitmap(p.bytes), s.box);
            } catch (_) {}
          case SlideText t:
            var y = t.box.top;
            for (final para in t.paras) {
              final runs = para.runs.where((r) => r.text.isNotEmpty).toList();
              if (runs.isEmpty) {
                y += 12;
                continue;
              }
              final sizePt = runs.first.size ?? (t.title ? 28.0 : 16.0);
              final text = '${para.bullet ? '• ' : ''}${runs.map((r) => r.text).join()}';
              final font = fonts.get(runs.first.font, sizePt, bold: runs.first.bold || t.title, italic: runs.first.italic, text: text);
              final indent = para.level * 18.0;
              final bounds = Rect.fromLTWH(t.box.left + indent, y, math.max(20, t.box.width - indent), 0);
              final el = sf.PdfTextElement(text: text, font: font, brush: sf.PdfSolidBrush(_c(runs.first.color ?? 0xFF000000)));
              el.stringFormat = sf.PdfStringFormat(
                  alignment: switch (para.align) { ParaAlign.center => sf.PdfTextAlignment.center, ParaAlign.right => sf.PdfTextAlignment.right, ParaAlign.justify => sf.PdfTextAlignment.justify, _ => sf.PdfTextAlignment.left });
              final res = el.draw(graphics: g, bounds: bounds);
              y = (res?.bounds.bottom ?? (y + font.height)) + sizePt * 0.25;
            }
          case SlideTable tbl:
            final cols = tbl.rows.fold<int>(0, (m, r) => math.max(m, r.length));
            if (cols == 0) continue;
            final grid = sf.PdfGrid();
            grid.columns.add(count: cols);
            final fs = (s.box.height / math.max(1, tbl.rows.length) * 0.4).clamp(6.0, 16.0);
            grid.style = sf.PdfGridStyle(font: fonts.get(null, fs, text: tbl.rows.expand((r) => r).join()), cellPadding: sf.PdfPaddings(left: 3, right: 3, top: 2, bottom: 2));
            for (var r = 0; r < tbl.rows.length; r++) {
              final row = grid.rows.add();
              for (var c = 0; c < cols; c++) {
                row.cells[c].value = c < tbl.rows[r].length ? tbl.rows[r][c] : '';
              }
              if (r == 0 && tbl.header) row.style = sf.PdfGridRowStyle(backgroundBrush: sf.PdfSolidBrush(sf.PdfColor(31, 78, 121)), textBrush: sf.PdfBrushes.white);
            }
            grid.draw(graphics: g, bounds: Rect.fromLTWH(s.box.left, s.box.top, s.box.width, 0));
          case SlideChart ch:
            _drawChart(g, ch, fonts);
        }
      }
    }
    if (doc.pages.count == 0) throw const FormatException('No slides selected.');
    return Uint8List.fromList(doc.saveSync());
  } finally {
    doc.dispose();
  }
}

void _drawChart(sf.PdfGraphics g, SlideChart ch, PdfFonts fonts) {
  final b = ch.box;
  final d = ch.data;
  final small = fonts.get(null, 8);
  g.drawRectangle(pen: sf.PdfPen(sf.PdfColor(200, 200, 200)), bounds: b);
  if (!d.hasData || d.series.isEmpty) {
    g.drawString('Chart (no stored data in the file)', small, brush: sf.PdfBrushes.gray, bounds: b, format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.center, lineAlignment: sf.PdfVerticalAlignment.middle));
    return;
  }
  if (d.title.isNotEmpty) g.drawString(d.title, fonts.get(null, 10, bold: true, text: d.title), brush: sf.PdfBrushes.black, bounds: Rect.fromLTWH(b.left, b.top + 2, b.width, 14), format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.center));
  final plot = Rect.fromLTRB(b.left + 30, b.top + 20, b.right - 8, b.bottom - 22);
  final values = d.series.expand((s) => s.values).whereType<double>().toList();
  final maxV = values.isEmpty ? 1.0 : math.max(values.reduce(math.max), 0.0);
  final minV = values.isEmpty ? 0.0 : math.min(values.reduce(math.min), 0.0);
  final span = (maxV - minV) == 0 ? 1.0 : maxV - minV;
  final zeroY = plot.bottom - (0 - minV) / span * plot.height;
  g.drawLine(sf.PdfPen(sf.PdfColor(120, 120, 120)), Offset(plot.left, zeroY), Offset(plot.right, zeroY));
  g.drawString(_fmt(maxV), small, brush: sf.PdfBrushes.gray, bounds: Rect.fromLTWH(b.left + 2, plot.top - 4, 28, 10));
  const palette = [0xFF1F77B4, 0xFFFF7F0E, 0xFF2CA02C, 0xFFD62728, 0xFF9467BD, 0xFF8C564B];
  final n = math.max(1, d.categories.length);
  final groupW = plot.width / n;
  final barW = groupW * 0.8 / d.series.length;
  for (var c = 0; c < n; c++) {
    for (var s = 0; s < d.series.length; s++) {
      final v = c < d.series[s].values.length ? d.series[s].values[c] : null;
      if (v == null) continue;
      final y = plot.bottom - (v - minV) / span * plot.height;
      final x = plot.left + c * groupW + groupW * 0.1 + s * barW;
      g.drawRectangle(brush: sf.PdfSolidBrush(_c(palette[s % palette.length])), bounds: Rect.fromLTRB(x, math.min(y, zeroY), x + barW * 0.95, math.max(y, zeroY)));
    }
    if (c < d.categories.length) {
      g.drawString(d.categories[c], fonts.get(null, 7, text: d.categories[c]), brush: sf.PdfBrushes.black, bounds: Rect.fromLTWH(plot.left + c * groupW, plot.bottom + 2, groupW, 10), format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.center));
    }
  }
}

String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
