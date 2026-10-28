import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../model/doc_model.dart' show xmlEscape;
import '../ooxml/opc.dart';
import 'layout_model.dart';
import 'ocr_review.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _wp = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _pic = 'http://schemas.openxmlformats.org/drawingml/2006/picture';

int _tw(double pt) => (pt * 20).round(); // twips
int _emu(double pt) => (pt * 12700).round();
String _hex(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// Share of an exact line height above the baseline. Word processors place
/// the baseline at ascent / (ascent + descent) of the line box; for Arial and
/// Times this is 0.81 (measured with LibreOffice, see test/layout_test.dart).
const baselineRatio = 0.81;

/// Margin kept on every side of a rebuilt page (points).
const pageMargin = 14.0;

/// Writes pages as a DOCX in which every source page is one Word page with
/// the same size and orientation (one section per page).
///
/// A page with a [LayoutPage.background] (faithful mode) is that image,
/// anchored behind the text at the page's exact size, plus one tiny empty
/// paragraph, so it can't spill onto a second page. Other pages are rebuilt
/// from their lines, tables, shaded bands and graphics: text is real Word
/// text positioned with exact line heights, spacing, indents and tab stops;
/// tables are Word tables; graphics are anchored at their page positions.
///
/// Words read with low OCR confidence are wrapped in hidden bookmarks
/// (`_OCR_<n>`) and listed in [review] when given, so they can be checked
/// and corrected later; they are highlighted only with [highlightUncertain]
/// (a review copy). Words left out of the text (stamp text, noise) are
/// listed in [review] too.
Uint8List writeLayoutDocx(List<LayoutPage> pages, {String title = '', bool highlightUncertain = false, List<OcrReviewItem>? review}) {
  final opc = OpcWriter();
  final rels = Rels();
  rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles', 'styles.xml');
  rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings', 'settings.xml');
  final body = StringBuffer();
  var imageNo = 0;
  var drawingId = 1;

  String embed(LGraphic g) {
    imageNo++;
    final name = 'media/image$imageNo.${g.ext == 'jpeg' ? 'jpeg' : 'png'}';
    opc.addBinary('word/$name', g.bytes);
    return rels.add(relImage, name);
  }

  String anchor(LGraphic g, {bool behind = false}) {
    final rid = embed(g);
    final id = drawingId++;
    final cx = _emu(g.box.width), cy = _emu(g.box.height);
    final label = switch (g.kind) {
      GraphicKind.qrCode => 'QR code',
      GraphicKind.stamp => 'Stamp or seal',
      GraphicKind.signature => 'Signature',
      GraphicKind.photo => 'Photo',
      GraphicKind.logo => 'Logo',
      GraphicKind.pageImage => 'Page image',
      GraphicKind.graphic => 'Graphic',
    };
    return '<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="${behind ? 1 : 100 + id}" '
        'behindDoc="${behind ? 1 : 0}" locked="${behind ? 1 : 0}" layoutInCell="1" allowOverlap="1">'
        '<wp:simplePos x="0" y="0"/>'
        '<wp:positionH relativeFrom="page"><wp:posOffset>${_emu(g.box.left)}</wp:posOffset></wp:positionH>'
        '<wp:positionV relativeFrom="page"><wp:posOffset>${_emu(g.box.top)}</wp:posOffset></wp:positionV>'
        '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>'
        '<wp:docPr id="$id" name="$label $id" descr="$label"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="$id" name="$label $id"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>';
  }

  for (var pi = 0; pi < pages.length; pi++) {
    final page = pages[pi];
    final last = pi == pages.length - 1;
    final sect = _sect(page.size, last: last);
    if (page.background != null) {
      // Faithful page: one empty 1-pt paragraph holding the page image.
      final bg = LGraphic(page.background!.box, page.background!.bytes, page.background!.ext, page.background!.pixelWidth,
          page.background!.pixelHeight,
          kind: GraphicKind.pageImage);
      body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/>${last ? '' : sect}<w:rPr><w:sz w:val="2"/></w:rPr></w:pPr>'
          '${anchor(bg, behind: true)}</w:p>');
      continue;
    }
    final w = _PageWriter(page, highlightUncertain, pi + 1, review);
    for (final (text, box) in page.omitted) {
      review?.add(OcrReviewItem(id: 0, page: pi + 1, text: text, box: box, omitted: true));
    }
    final paras = w.build();
    // Graphics are anchored to the first paragraph of the page.
    final anchors = page.graphics.map((g) => anchor(g)).join();
    if (paras.isEmpty) {
      body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/>${last ? '' : sect}</w:pPr>$anchors</w:p>');
      continue;
    }
    var first = true;
    for (var i = 0; i < paras.length; i++) {
      var x = paras[i];
      if (first && x.startsWith('<w:p>')) {
        x = x.replaceFirst('</w:pPr>', '</w:pPr>$anchors');
        first = false;
      }
      body.write(x);
    }
    if (first) {
      body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/></w:pPr>$anchors</w:p>');
    }
    // Section break closing this page (an empty, minimal paragraph).
    if (!last) body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/>$sect<w:rPr><w:sz w:val="2"/></w:rPr></w:pPr></w:p>');
  }
  final lastSect = pages.isEmpty ? _sect(const Size(595.28, 841.89), last: true) : _sect(pages.last.size, last: true);
  final doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="$_w" xmlns:r="$_r" xmlns:wp="$_wp" xmlns:a="$_a" xmlns:pic="$_pic"><w:body>$body$lastSect</w:body></w:document>';
  opc.addXml('word/document.xml', doc, contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml');
  opc.addXml('word/styles.xml', _styles, contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml');
  opc.addXml('word/settings.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings xmlns:w="$_w"><w:defaultTabStop w:val="720"/><w:compat><w:doNotExpandShiftReturn/></w:compat></w:settings>',
      contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml');
  opc.addXml('word/_rels/document.xml.rels', rels.xml());
  final root = Rels()
    ..add(relOfficeDoc, 'word/document.xml')
    ..add(relCore, 'docProps/core.xml')
    ..add(relApp, 'docProps/app.xml');
  opc.addXml('_rels/.rels', root.xml());
  opc.addXml('docProps/core.xml', corePropsXml(title), contentType: 'application/vnd.openxmlformats-package.core-properties+xml');
  opc.addXml('docProps/app.xml', appPropsXml(), contentType: 'application/vnd.openxmlformats-officedocument.extended-properties+xml');
  return opc.finish();
}

String _sect(Size s, {required bool last}) {
  final m = _tw(pageMargin);
  return '<w:sectPr>${last ? '' : '<w:type w:val="nextPage"/>'}'
      '<w:pgSz w:w="${_tw(s.width)}" w:h="${_tw(s.height)}"${s.width > s.height ? ' w:orient="landscape"' : ''}/>'
      '<w:pgMar w:top="$m" w:right="$m" w:bottom="$m" w:left="$m" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>';
}

/// A paragraph to write: one or more lines sharing a style.
class _Para {
  final List<LLine> lines;
  final double size;
  double lineHeight; // exact, points
  final String align; // left | center | right
  double left; // indent from the page's left edge (points)
  final double right; // indent from the page's right edge (points)
  double firstLine = 0; // first line's offset from [left] (multi-line paragraphs)
  final List<(double, String)> tabs; // position from the page's left edge, kind (left/right)
  final List<List<LWord>> segments; // single-line paragraphs with tabs
  _Para(this.lines, this.size, this.lineHeight, this.align, this.left, this.right, this.tabs, this.segments);
  double get firstBaseline => lines.first.baseline;
  double get top => firstBaseline - lineHeight * baselineRatio;
  double get bottom => top + lineHeight * lines.length;
}

/// Lays out one page as a sequence of paragraphs and tables whose vertical
/// positions follow the source page.
class _PageWriter {
  final LayoutPage page;
  final bool highlight;
  final int pageNo;
  final List<OcrReviewItem>? review;
  _PageWriter(this.page, this.highlight, this.pageNo, this.review);

  double get pw => page.size.width;

  List<String> build() {
    final items = <(double, String, double)>[]; // top, xml, bottom
    // Lines inside shaded bands belong to the band.
    final banded = <LShade, List<LLine>>{for (final s in page.shades) s: []};
    final free = <LLine>[];
    for (final l in page.lines) {
      final c = l.box.center;
      final s = page.shades.where((s) => s.box.contains(c)).firstOrNull;
      if (s != null) {
        banded[s]!.add(l);
      } else {
        free.add(l);
      }
    }
    final paras = _paragraphs(free);
    _alignColumns(paras);
    // Lines closer together than their natural line height: use the actual
    // pitch for both, so neither pushes the other down.
    for (var i = 0; i + 1 < paras.length; i++) {
      final a = paras[i], b = paras[i + 1];
      if (a.bottom <= b.top + 0.1) continue;
      final pitch = b.firstBaseline - a.lines.last.baseline;
      if (pitch <= 0) continue;
      if (a.lines.length == 1) a.lineHeight = math.max(a.size * 1.0, math.min(a.lineHeight, pitch));
      if (b.lines.length == 1) b.lineHeight = math.max(b.size * 1.0, math.min(b.lineHeight, pitch));
    }
    for (final p in paras) {
      items.add((p.top, _paraXml(p), p.bottom));
    }
    for (final e in banded.entries) {
      items.add((e.key.box.top, _shadeXml(e.key, e.value), e.key.box.bottom));
    }
    for (final t in page.tables) {
      items.add((t.box.top, _tableXml(t), t.box.bottom));
    }
    items.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <String>[];
    var cursor = pageMargin;
    for (final (top, xml, bottom) in items) {
      final gap = top - cursor;
      if (xml.startsWith('<w:tbl>')) {
        // Tables can't have space before; a spacer paragraph of the exact
        // height moves them down.
        if (gap >= 0.5) out.add(_spacer(gap));
        out.add(xml);
        // A table must be followed by a paragraph; keep it 1 pt high.
        out.add(_spacer(1));
        cursor = math.max(cursor, bottom) + 1;
      } else {
        out.add(xml.replaceFirst('w:before="0"', 'w:before="${_tw(math.max(0, gap))}"'));
        cursor = math.max(cursor + math.max(0, gap), bottom);
      }
    }
    return out;
  }

  /// Label/value blocks (consecutive single lines with tab stops, like
  /// "Name : value"): starts and stops within a few points of each other
  /// are aligned to one position, so labels, colons and values line up as
  /// they do in the source instead of drifting with measurement noise.
  void _alignColumns(List<_Para> paras) {
    bool tabular(_Para p) => p.lines.length == 1 && p.align == 'left';
    var i = 0;
    while (i < paras.length) {
      if (!tabular(paras[i]) || paras[i].tabs.isEmpty) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < paras.length && tabular(paras[j]) && paras[j].top - paras[j - 1].bottom < paras[j - 1].lineHeight * 1.5) {
        j++;
      }
      final block = paras.sublist(i, j);
      if (block.length >= 2) {
        final tol = math.max(5.0, pw * 0.01);
        final xs = <double>[
          for (final p in block) ...[p.left, ...p.tabs.map((t) => t.$1)],
        ]..sort();
        final clusters = <List<double>>[];
        for (final x in xs) {
          if (clusters.isNotEmpty && x - clusters.last.first <= tol) {
            clusters.last.add(x);
          } else {
            clusters.add([x]);
          }
        }
        double snap(double x) {
          for (final c in clusters) {
            if (c.length > 1 && x >= c.first - 0.01 && x <= c.last + 0.01) return median(c);
          }
          return x;
        }

        for (final p in block) {
          p.left = snap(p.left);
          for (var k = 0; k < p.tabs.length; k++) {
            p.tabs[k] = (snap(p.tabs[k].$1), p.tabs[k].$2);
          }
        }
      }
      i = j;
    }
  }

  static String _spacer(double h) =>
      '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="${math.max(20, _tw(h))}" w:lineRule="exact"/><w:rPr><w:sz w:val="2"/></w:rPr></w:pPr></w:p>';

  // ---- paragraphs ---------------------------------------------------------

  /// Words separated by a gap wider than about three spaces form separate
  /// segments, written with tab stops at their original positions.
  List<List<LWord>> _segments(LLine l) {
    final segs = <List<LWord>>[];
    final size = l.size;
    for (final w in l.words) {
      if (segs.isEmpty) {
        segs.add([w]);
        continue;
      }
      final gap = w.box.left - segs.last.last.box.right;
      if (gap > math.max(size * 0.95, pw * 0.018)) {
        segs.add([w]);
      } else {
        segs.last.add(w);
      }
    }
    return segs;
  }

  bool _centered(LLine l) {
    final b = l.box;
    final c = b.center.dx;
    return (c - pw / 2).abs() < pw * 0.03 && b.left > pw * 0.12 && _segments(l).length == 1;
  }

  List<_Para> _paragraphs(List<LLine> lines) {
    final sorted = [...lines]..sort((a, b) => a.baseline.compareTo(b.baseline));
    final groups = <List<LLine>>[];
    for (final l in sorted) {
      if (groups.isNotEmpty && _continues(groups.last, l)) {
        groups.last.add(l);
      } else {
        groups.add([l]);
      }
    }
    return [for (final g in groups) _para(g)];
  }

  /// Whether [l] continues the paragraph [g] (a wrapped line).
  bool _continues(List<LLine> g, LLine l) {
    final prev = g.last;
    if (_segments(prev).length > 1 || _segments(l).length > 1) return false;
    if (_centered(prev) || _centered(l)) return false;
    final sp = prev.size, sl = l.size;
    if ((sp - sl).abs() > math.max(sp, sl) * 0.15) return false;
    final pitch = l.baseline - prev.baseline;
    if (pitch <= 0 || pitch > math.max(sp, sl) * 1.75) return false;
    if (g.length > 1) {
      final p0 = prev.baseline - g[g.length - 2].baseline;
      if ((pitch - p0).abs() > p0 * 0.3) return false;
    }
    if ((l.box.left - g.first.box.left).abs() > pw * 0.02) return false;
    // The previous line must have been full (wrapped at the right edge).
    final right = g.map((x) => x.box.right).reduce(math.max);
    if (prev.box.right < right - pw * 0.12 && g.length > 1) return false;
    final avail = pw - pageMargin - prev.box.right;
    final nextWord = textAdvance(l.words.first.text) * sl;
    if (g.length == 1 && avail > nextWord + sl * 2 && prev.box.right < pw * 0.7) return false;
    return true;
  }

  _Para _para(List<LLine> g) {
    final size = halfPoint(median(g.map((l) => l.size)));
    final first = g.first;
    double lineHeight;
    if (g.length > 1) {
      lineHeight = median([for (var i = 1; i < g.length; i++) g[i].baseline - g[i - 1].baseline]);
    } else {
      lineHeight = size * 1.2;
    }
    lineHeight = math.max(lineHeight, size * 1.02);
    final segs = g.length == 1 ? _segments(first) : [first.words];
    if (g.length == 1 && _centered(first)) {
      final c = first.box.center.dx;
      final half = math.min(c - pageMargin, pw - pageMargin - c);
      return _Para(g, size, lineHeight, 'center', c - half, pw - (c + half), const [], segs);
    }
    var left = clampD(first.box.left, pageMargin, pw - pageMargin - 10);
    var firstLine = 0.0;
    if (g.length > 1) {
      // Continuation lines may start elsewhere than the first (hanging or
      // first-line indents, or a slightly tilted photo).
      final rest = clampD(median(g.skip(1).map((l) => l.box.left)), pageMargin, pw - pageMargin - 10);
      firstLine = left - rest;
      left = rest;
    }
    final tabs = <(double, String)>[for (var i = 1; i < segs.length; i++) (segs[i].first.box.left, 'left')];
    double right;
    right = pageMargin; // lines end where the source's lines end (explicit breaks)
    return _Para(g, size, lineHeight, 'left', left, right, tabs, segs)..firstLine = firstLine;
  }

  /// Letter spacing (points) that makes the words as wide as measured in
  /// the source (letter-spaced titles). Small differences are ignored and
  /// large ones limited.
  static double _tracking(List<LWord> words, double size) {
    if (words.isEmpty || !words.every((w) => hasMetrics(w.font))) return 0;
    var target = 0.0, natural = 0.0, gaps = 0;
    for (final w in words) {
      // Short words and words read with low confidence measure poorly.
      if (w.text.length < 2 || (w.confidence ?? 1) < 0.5) continue;
      target += w.box.width;
      // Ink is a little narrower than advance widths (side bearings).
      natural += textAdvance(w.text, bold: w.bold, italic: w.italic, serif: isSerifFont(w.font)) * size - size * 0.07;
      gaps += w.text.length - 1;
    }
    if (gaps < 3) return 0;
    final d = (target - natural) / gaps;
    if (d.abs() < 0.1) return 0;
    return clampD(d, -size * 0.06, size * 0.2);
  }

  /// Spacing for the space run before [b] so that [b] starts where it
  /// starts in the source: the distance between the two words' left edges
  /// minus what word [a] (with letter spacing) and a plain space take up.
  static double _gapExtra(LWord a, LWord b, double size, double track) {
    if (!hasMetrics(a.font) || !hasMetrics(b.font)) return 0;
    final serif = isSerifFont(a.font);
    final used = textAdvance(a.text, bold: a.bold, italic: a.italic, serif: serif) * size + a.text.length * track + textAdvance(' ', bold: b.bold, serif: serif) * size;
    return clampD(b.box.left - a.box.left - used, -size * 0.15, size * 1.5);
  }

  String _runs(List<LWord> words, double size, {bool tabBefore = false}) {
    final sb = StringBuffer();
    final track = _tracking(words, size);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (i > 0) {
        // The space between words is its own run so its width can match.
        final extra = _gapExtra(words[i - 1], w, size, track);
        // The space's own font size sets its width (character spacing on a
        // lone space is not applied by every word processor).
        final space = textAdvance(' ', bold: w.bold, serif: isSerifFont(w.font));
        if (extra >= 0.2) {
          // Wider gap: letter spacing on the space.
          sb.write(_run(' ', w.underline && words[i - 1].underline ? w : _plain(w), size, tracking: extra, noHighlight: true));
        } else if (extra <= -0.2) {
          // Narrower gap: a smaller space (spacing on a lone space is not
          // applied by every word processor). Never less than 60%.
          final spaceSize = clampD((space * size + extra) / space, size * 0.6, size);
          sb.write(_run(' ', w.underline && words[i - 1].underline ? w : _plain(w), (spaceSize * 2).round() / 2, noHighlight: true));
        } else {
          sb.write(_run(' ', w.underline && words[i - 1].underline ? w : _plain(w), size, noHighlight: true));
        }
      }
      final run = _run(w.text, w, w.size > 0 && (w.size - size).abs() > 0.4 ? halfPoint(w.size) : size, tab: tabBefore && i == 0, tracking: track);
      final rv = review;
      if (w.uncertain && rv != null) {
        // A hidden bookmark marks the word for review and correction.
        final n = rv.where((x) => !x.omitted).length + 1;
        final id = n;
        rv.add(OcrReviewItem(id: n, page: pageNo, text: w.text, confidence: w.confidence, context: words.map((x) => x.text).join(' '), box: w.box));
        final tabRun = run.startsWith('<w:r><w:rPr>') && run.contains('<w:tab/>') ? run.substring(0, run.indexOf('</w:r>') + 6) : '';
        sb.write('$tabRun<w:bookmarkStart w:id="$id" w:name="_OCR_$n"/>${run.substring(tabRun.length)}<w:bookmarkEnd w:id="$id"/>');
      } else {
        sb.write(run);
      }
    }
    return sb.toString();
  }

  static LWord _plain(LWord w) =>
      LWord(w.text, w.box, size: w.size, bold: w.bold, italic: w.italic, color: w.color, font: w.font, confidence: w.confidence);

  String _run(String text, LWord w, double size, {bool tab = false, double tracking = 0, bool noHighlight = false}) {
    final pr = StringBuffer();
    final f = xmlEscape(w.font);
    // Devanagari is a complex script in Word: it takes the cs font, which
    // must have the glyphs (Mangal ships with Windows; others substitute).
    final deva = text.runes.any((r) => r >= 0x900 && r <= 0x97f);
    pr.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="${deva ? 'Mangal' : f}"/>');
    if (w.bold) pr.write('<w:b/><w:bCs/>');
    if (w.italic) pr.write('<w:i/><w:iCs/>');
    if ((w.color & 0xFFFFFF) != 0) pr.write('<w:color w:val="${_hex(w.color)}"/>');
    final hs = (size * 2).round();
    if (tracking != 0) pr.write('<w:spacing w:val="${_tw(tracking)}"/>');
    pr.write('<w:sz w:val="$hs"/><w:szCs w:val="$hs"/>');
    if (highlight && w.uncertain && !noHighlight) pr.write('<w:highlight w:val="yellow"/>');
    final sb = StringBuffer();
    if (tab) sb.write('<w:r><w:rPr>$pr</w:rPr><w:tab/></w:r>');
    if (w.underline) pr.write('<w:u w:val="single"/>');
    if (deva) pr.write('<w:lang w:bidi="hi-IN"/>'); // last in schema order
    sb.write('<w:r><w:rPr>$pr</w:rPr><w:t xml:space="preserve">${xmlEscape(text)}</w:t></w:r>');
    return sb.toString();
  }

  String _pPr(_Para p, {String extra = ''}) {
    final tabs = p.tabs.isEmpty
        ? ''
        : '<w:tabs>${p.tabs.map((t) => '<w:tab w:val="${t.$2}" w:pos="${_tw(t.$1 - pageMargin)}"/>').join()}</w:tabs>';
    return '<w:pPr>$tabs<w:spacing w:before="0" w:after="0" w:line="${_tw(p.lineHeight)}" w:lineRule="exact"/>'
        '<w:ind w:left="${_tw(math.max(0, p.left - pageMargin))}" w:right="${_tw(math.max(0, p.right - pageMargin))}"'
        '${p.firstLine.abs() < 0.3 ? '' : p.firstLine > 0 ? ' w:firstLine="${_tw(p.firstLine)}"' : ' w:hanging="${_tw(-p.firstLine)}"'}/>'
        '${p.align == 'left' ? '' : '<w:jc w:val="${p.align}"/>'}$extra</w:pPr>';
  }

  String _paraXml(_Para p) {
    final sb = StringBuffer('<w:p>${_pPr(p)}');
    if (p.lines.length == 1) {
      for (var i = 0; i < p.segments.length; i++) {
        sb.write(_runs(p.segments[i], p.size, tabBefore: i > 0));
      }
    } else {
      // The source's line breaks are kept (soft breaks), so the text wraps
      // exactly as in the original and stays editable.
      for (var i = 0; i < p.lines.length; i++) {
        if (i > 0) sb.write('<w:r><w:br/></w:r>');
        sb.write(_runs(p.lines[i].words, p.size));
      }
    }
    sb.write('</w:p>');
    return sb.toString();
  }

  // ---- shaded bands ---------------------------------------------------------

  /// A shaded heading band: a one-cell borderless table with the band's
  /// colour and exact height, text centred vertically.
  String _shadeXml(LShade s, List<LLine> lines) {
    final b = s.box;
    final sb = StringBuffer('<w:tbl><w:tblPr><w:tblW w:w="${_tw(b.width)}" w:type="dxa"/>'
        '<w:tblInd w:w="${_tw(b.left - pageMargin)}" w:type="dxa"/><w:tblLayout w:type="fixed"/>'
        '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="0" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="0" w:type="dxa"/></w:tblCellMar>'
        '</w:tblPr><w:tblGrid><w:gridCol w:w="${_tw(b.width)}"/></w:tblGrid>'
        '<w:tr><w:trPr><w:trHeight w:val="${_tw(b.height)}" w:hRule="exact"/></w:trPr>'
        '<w:tc><w:tcPr><w:tcW w:w="${_tw(b.width)}" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="${_hex(s.color)}"/><w:vAlign w:val="top"/></w:tcPr>');
    if (lines.isEmpty) {
      sb.write('<w:p/>');
    } else {
      // Lines sit at their measured baselines and left edges inside the band.
      var cursor = b.top;
      for (final l in [...lines]..sort((x, y) => x.baseline.compareTo(y.baseline))) {
        final size = halfPoint(l.size);
        final lh = size * 1.15;
        final top = l.baseline - lh * baselineRatio;
        final before = math.max(0.0, top - cursor);
        cursor = top + lh;
        final c = l.box.center.dx - b.left;
        final centered = (l.box.center.dx - b.center.dx).abs() < b.width * 0.03;
        final half = math.min(c, b.width - c);
        final ind = centered
            ? '<w:ind w:left="${_tw(math.max(0, c - half))}" w:right="${_tw(math.max(0, b.width - c - half))}"/><w:jc w:val="center"/>'
            : '<w:ind w:left="${_tw(math.max(0, l.box.left - b.left))}" w:right="0"/>';
        sb.write('<w:p><w:pPr><w:spacing w:before="${_tw(before)}" w:after="0" w:line="${_tw(lh)}" w:lineRule="exact"/>$ind</w:pPr>${_runs(l.words, size)}</w:p>');
      }
    }
    sb.write('</w:tc></w:tr></w:tbl>');
    return sb.toString();
  }

  // ---- tables -------------------------------------------------------------

  String _tableXml(LTable t) {
    final widths = [for (var c = 0; c < t.columns; c++) t.colX[c + 1] - t.colX[c]];
    final bw = (t.borderWidth * 8).round().clamp(2, 48);
    final border = t.borders ? 'w:val="single" w:sz="$bw" w:space="0" w:color="${_hex(t.borderColor)}"' : 'w:val="nil"';
    final sb = StringBuffer('<w:tbl><w:tblPr><w:tblW w:w="${_tw(t.box.width)}" w:type="dxa"/>'
        '<w:tblInd w:w="${_tw(t.box.left - pageMargin)}" w:type="dxa"/>'
        '<w:tblBorders><w:top $border/><w:left $border/><w:bottom $border/><w:right $border/><w:insideH $border/><w:insideV $border/></w:tblBorders>'
        '<w:tblLayout w:type="fixed"/>'
        '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="60" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="60" w:type="dxa"/></w:tblCellMar>'
        '</w:tblPr><w:tblGrid>${widths.map((w) => '<w:gridCol w:w="${_tw(w)}"/>').join()}</w:tblGrid>');
    // Cells covering each grid position.
    LCell? at(int r, int c) => t.cells.where((x) => r >= x.row && r < x.row + x.rowSpan && c >= x.col && c < x.col + x.colSpan).firstOrNull;
    for (var r = 0; r < t.rows; r++) {
      final h = t.rowY[r + 1] - t.rowY[r];
      sb.write('<w:tr><w:trPr><w:cantSplit/><w:trHeight w:val="${_tw(h)}" w:hRule="exact"/></w:trPr>');
      var c = 0;
      while (c < t.columns) {
        final cell = at(r, c) ?? LCell(r, c);
        final span = cell.colSpan;
        final w = widths.sublist(c, math.min(t.columns, c + span)).fold<double>(0, (a, b) => a + b);
        final pr = StringBuffer('<w:tcPr><w:tcW w:w="${_tw(w)}" w:type="dxa"/>');
        if (span > 1) pr.write('<w:gridSpan w:val="$span"/>');
        if (cell.rowSpan > 1) pr.write(cell.row == r ? '<w:vMerge w:val="restart"/>' : '<w:vMerge/>');
        if (cell.shade != null) pr.write('<w:shd w:val="clear" w:color="auto" w:fill="${_hex(cell.shade!)}"/>');
        final rect = Rect.fromLTRB(t.colX[cell.col], t.rowY[cell.row], t.colX[math.min(t.columns, cell.col + cell.colSpan)], t.rowY[math.min(t.rows, cell.row + cell.rowSpan)]);
        pr.write('<w:vAlign w:val="${_vAlign(cell, rect)}"/></w:tcPr>');
        sb.write('<w:tc>$pr');
        if (cell.row != r || cell.lines.isEmpty) {
          sb.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="${_tw(8)}" w:lineRule="exact"/></w:pPr></w:p>');
        } else {
          for (final l in cell.lines) {
            sb.write(_cellPara(l, rect));
          }
        }
        sb.write('</w:tc>');
        c += span;
      }
      sb.write('</w:tr>');
    }
    sb.write('</w:tbl>');
    return sb.toString();
  }

  static String _vAlign(LCell cell, Rect rect) {
    if (cell.lines.isEmpty) return 'top';
    final top = cell.lines.first.box.top - rect.top;
    final bottom = rect.bottom - cell.lines.last.box.bottom;
    if ((top - bottom).abs() < rect.height * 0.2) return 'center';
    return top < bottom ? 'top' : 'bottom';
  }

  String _cellPara(LLine l, Rect cell) {
    final size = halfPoint(l.size);
    final lg = l.box.left - cell.left, rg = cell.right - l.box.right;
    String jc;
    if ((lg - rg).abs() < cell.width * 0.15) {
      jc = 'center';
    } else if (rg < lg) {
      jc = 'right';
    } else {
      jc = 'left';
    }
    final ind = jc == 'left' ? '<w:ind w:left="${_tw(math.max(0, lg - 3))}"/>' : (jc == 'right' ? '<w:ind w:right="${_tw(math.max(0, rg - 3))}"/>' : '');
    return '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="${_tw(size * 1.2)}" w:lineRule="exact"/>$ind'
        '${jc == 'left' ? '' : '<w:jc w:val="$jc"/>'}</w:pPr>${_runs(l.words, size)}</w:p>';
  }
}

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="$_w">'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
    '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>'
    '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="60" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="60" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
    '</w:styles>';
