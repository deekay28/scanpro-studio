import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'model/doc_model.dart';
import 'model/page_content.dart';
import 'ooxml/pptx.dart';
import 'table_extraction.dart';

enum WordMode { editable, layout }

class DocBuildResult {
  final DocModel doc;
  final List<String> warnings;
  const DocBuildResult(this.doc, this.warnings);
}

/// Content-level warnings shared by all PDF exports.
List<String> contentWarnings(List<PageContent> pages) {
  final w = <String>[];
  final multi = [for (final p in pages) if (p.multiColumn) p.index + 1];
  if (multi.isNotEmpty) w.add('Pages ${_ranges(multi)} have several text columns; check the reading order.');
  final ocr = [for (final p in pages) if (p.fromOcr) p.index + 1];
  if (ocr.isNotEmpty) w.add('Pages ${_ranges(ocr)} are scans; their text comes from OCR and may contain recognition errors. Handwriting is usually not recognised.');
  final unsure = pages.fold<int>(0, (n, p) => n + p.uncertainWords);
  if (unsure > 0) w.add('$unsure OCR word(s) have low confidence and are flagged for review.');
  final noText = [for (final p in pages) if (!p.hasText && p.images.isNotEmpty) p.index + 1];
  if (noText.isNotEmpty) w.add('Pages ${_ranges(noText)} contain only images; their content is kept as pictures, not editable text.');
  final math = pages.any((p) => p.lines.any((l) => RegExp(r'[∑∫√∂∞≤≥≠±∏∆∇∈∉⊂⊃∀∃]').hasMatch(l.text)));
  if (math) w.add('Mathematical notation was found; formulas are converted as plain text and may lose their layout.');
  return w;
}

String _ranges(List<int> pages) {
  if (pages.length > 8) return '${pages.take(8).join(', ')}…';
  return pages.join(', ');
}

String _norm(String s) => s.replaceAll(RegExp(r'\d+'), '#').replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// Lines repeated near the top or bottom of most pages (running headers,
/// footers and page numbers).
({Set<PdfLine> lines, String header, String footer}) detectRunningLines(List<PageContent> pages) {
  final out = <PdfLine>{};
  if (pages.length < 2) return (lines: out, header: '', footer: '');
  // Short documents need an exact repeat; longer ones tolerate changing
  // numbers (page numbers).
  String norm(String t) => pages.length < 3 ? t.trim().toLowerCase() : _norm(t);
  final counts = <String, int>{};
  for (final p in pages) {
    final seen = <String>{};
    for (final l in p.lines) {
      if (l.box.top < p.size.height * 0.09 || l.box.bottom > p.size.height * 0.92) {
        final k = '${l.box.top < p.size.height / 2 ? 'h' : 'f'}:${norm(l.text)}';
        if (seen.add(k)) counts[k] = (counts[k] ?? 0) + 1;
      }
    }
  }
  final need = math.max(2, (pages.length * 0.5).ceil());
  var header = '', footer = '';
  for (final p in pages) {
    final candidates = [
      for (final l in p.lines)
        if ((counts['${l.box.top < p.size.height / 2 ? 'h' : 'f'}:${norm(l.text)}'] ?? 0) >= need) l
    ];
    // Never treat a page's only content as a running header.
    if (candidates.length >= p.lines.length) continue;
    for (final l in candidates) {
      final top = l.box.top < p.size.height / 2;
      {
        out.add(l);
        // Keep running text without page numbers (numbers differ per page).
        final varies = RegExp(r'\d').hasMatch(l.text) && _norm(l.text) != l.text.toLowerCase();
        if (!varies) {
          if (top && header.isEmpty) header = l.text;
          if (!top && footer.isEmpty) footer = l.text;
        }
      }
    }
  }
  return (lines: out, header: header, footer: footer);
}

final _bullet = RegExp(r'^\s*([•●▪◦○■□\-–*·])\s+');
final _numbered = RegExp(r'^\s*(\d{1,3}[.)]|[a-z][.)]|[ivx]{1,4}[.)])\s+');

List<DocRun> _runs(List<PdfWord> words, double bodySize, {String? stripPrefix}) {
  final runs = <DocRun>[];
  var first = true;
  for (final w in words) {
    var t = w.text;
    if (first && stripPrefix != null && t.startsWith(stripPrefix)) {
      t = t.substring(stripPrefix.length).trimLeft();
    }
    first = false;
    if (t.isEmpty) continue;
    final size = (w.size * 2).round() / 2;
    final font = officeFontFor(w.font);
    final color = (w.color & 0xFFFFFF) == 0 ? null : w.color;
    final last = runs.isEmpty ? null : runs.last;
    if (last != null && last.bold == w.bold && last.italic == w.italic && last.size == size && last.color == color && last.font == font) {
      runs[runs.length - 1] = DocRun('${last.text} $t', bold: last.bold, italic: last.italic, size: size, color: color, font: font);
    } else {
      runs.add(DocRun(runs.isEmpty ? t : ' $t', bold: w.bold, italic: w.italic, size: size, color: color, font: font));
    }
  }
  return runs;
}

double _bodySize(List<PageContent> pages) {
  final sizes = <double>[];
  for (final p in pages) {
    for (final l in p.lines) {
      for (final w in l.words) {
        for (var i = 0; i < w.text.length; i++) {
          sizes.add(w.size);
        }
      }
    }
  }
  if (sizes.isEmpty) return 11;
  sizes.sort();
  return sizes[sizes.length ~/ 2];
}

/// Lines in reading order: in two-column pages the left column first.
List<PdfLine> readingOrder(PageContent p) {
  if (!p.multiColumn) return p.lines;
  final mid = p.size.width / 2;
  final full = <PdfLine>[], left = <PdfLine>[], right = <PdfLine>[];
  for (final l in p.lines) {
    if (l.box.left < mid - 4 && l.box.right > mid + 4) {
      full.add(l);
    } else if (l.box.center.dx < mid) {
      left.add(l);
    } else {
      right.add(l);
    }
  }
  // Full-width lines (titles) above the columns stay first.
  final top = left.isEmpty ? double.infinity : left.first.box.top;
  return [...full.where((l) => l.box.top < top), ...left, ...right, ...full.where((l) => l.box.top >= top)];
}

/// PDF pages → editable or layout-preserving [DocModel].
DocBuildResult buildDoc(List<PageContent> pages, {WordMode mode = WordMode.editable, String title = '', Map<int, List<ExtractedTable>>? tables}) {
  if (pages.isEmpty) return const DocBuildResult(DocModel([]), ['No pages selected.']);
  final warnings = contentWarnings(pages);
  final running = detectRunningLines(pages);
  final body = _bodySize(pages);
  final blocks = <DocBlock>[];
  final first = pages.first.size;
  if (mode == WordMode.layout) {
    var minLeft = double.infinity;
    for (final p in pages) {
      for (final l in p.lines) {
        minLeft = math.min(minLeft, l.box.left);
      }
    }
    final margin = minLeft.isFinite ? minLeft.clamp(18.0, 72.0) : 54.0;
    for (var pi = 0; pi < pages.length; pi++) {
      final p = pages[pi];
      for (final img in p.images) {
        blocks.add(DocImage(img.png, img.box.width, img.box.height, x: img.box.left, y: img.box.top));
      }
      var prevBottom = margin;
      // Lines on the same baseline become one paragraph separated by tabs.
      final rows = <List<PdfLine>>[];
      for (final l in p.lines) {
        if (rows.isNotEmpty && (rows.last.first.baseline - l.baseline).abs() < l.size * 0.4) {
          rows.last.add(l);
        } else {
          rows.add([l]);
        }
      }
      for (final row in rows) {
        row.sort((a, b) => a.box.left.compareTo(b.box.left));
        final top = row.map((l) => l.box.top).reduce(math.min);
        final runs = <DocRun>[];
        for (var i = 0; i < row.length; i++) {
          if (i > 0) runs.add(const DocRun('\t'));
          runs.addAll(_runs(row[i].words, body));
        }
        final gap = math.max(0.0, top - prevBottom - row.first.size * 0.2);
        blocks.add(DocParagraph(runs, indentLeft: math.max(0, row.first.box.left - margin), spaceBefore: double.parse(gap.toStringAsFixed(1))));
        prevBottom = row.map((l) => l.box.bottom).reduce(math.max);
      }
      blocks.add(DocPageBreak(pageWidth: p.size.width, pageHeight: p.size.height));
    }
    if (blocks.isNotEmpty && blocks.last is DocPageBreak) blocks.removeLast();
    final last = pages.last.size;
    return DocBuildResult(DocModel(blocks, pageWidth: last.width, pageHeight: last.height, margin: margin, title: title), warnings);
  }

  // Editable mode.
  final contentWidth = first.width - 2 * 54;
  var titleUsed = false;
  for (var pi = 0; pi < pages.length; pi++) {
    final p = pages[pi];
    final pageTables = tables?[p.index] ?? const TableExtractionService().extract(p);
    final items = <(double, DocBlock)>[];
    for (final t in pageTables) {
      items.add((t.bounds.top, DocTable([for (final r in t.rows) [for (final c in r) DocTableCell(c.text, bold: c.bold, number: c.number, uncertain: c.uncertain)]], headerRow: t.headerRow)));
    }
    for (final img in p.images) {
      final scale = img.box.width > contentWidth ? contentWidth / img.box.width : 1.0;
      items.add((img.box.top, DocImage(img.png, img.box.width * scale, img.box.height * scale)));
    }
    bool inTable(PdfLine l) => pageTables.any((t) => t.bounds.inflate(2).contains(l.box.center));
    final lines = readingOrder(p).where((l) => !running.lines.contains(l) && !inTable(l)).toList();
    // Merge lines into paragraphs.
    var cur = <PdfLine>[];
    void flush() {
      if (cur.isEmpty) return;
      final firstLine = cur.first;
      final size = firstLine.size;
      final text = firstLine.text;
      var style = ParaStyle.normal;
      String? prefix;
      final b = _bullet.firstMatch(text);
      final n = _numbered.firstMatch(text);
      if (b != null) {
        style = ParaStyle.bullet;
        prefix = b.group(1);
      } else if (n != null && cur.length <= 6) {
        style = ParaStyle.numbered;
        prefix = n.group(1);
      } else if (size >= body * 1.6 && cur.length <= 3) {
        style = !titleUsed && pi == 0 && size >= body * 2 ? ParaStyle.title : ParaStyle.h1;
        if (style == ParaStyle.title) titleUsed = true;
      } else if (size >= body * 1.3 && cur.length <= 3) {
        style = ParaStyle.h2;
      } else if (firstLine.bold && cur.length == 1 && text.length < 80 && size >= body * 0.95) {
        style = ParaStyle.h3;
      }
      final words = [for (final l in cur) ...l.words];
      final runs = _runs(words, body, stripPrefix: prefix);
      final c = firstLine.box.center.dx;
      final centred = cur.length <= 2 && (c - p.size.width / 2).abs() < p.size.width * 0.04 && firstLine.box.width < p.size.width * 0.7;
      items.add((firstLine.box.top, DocParagraph(runs, style: style, align: centred ? ParaAlign.center : ParaAlign.left)));
      cur = [];
    }

    for (final l in lines) {
      if (cur.isEmpty) {
        cur.add(l);
        continue;
      }
      final prev = cur.last;
      final gap = l.box.top - prev.box.bottom;
      final sameStyle = (l.size - prev.size).abs() < prev.size * 0.12 && l.bold == prev.bold;
      final aligned = (l.box.left - cur.first.box.left).abs() < prev.size * 2 || (l.box.left - prev.box.left).abs() < prev.size * 2;
      final newItem = _bullet.hasMatch(l.text) || _numbered.hasMatch(l.text);
      final sentenceEnd = RegExp(r'[.:!?]$').hasMatch(prev.text.trim());
      final shortPrev = prev.box.right < cur.first.box.left + (p.size.width - 2 * cur.first.box.left) * 0.75;
      if (gap > 0 && gap < prev.size * 0.9 && sameStyle && aligned && !newItem && !(sentenceEnd && shortPrev) && gap > -prev.size) {
        cur.add(l);
      } else {
        flush();
        cur.add(l);
      }
    }
    flush();
    items.sort((a, b) => a.$1.compareTo(b.$1));
    blocks.addAll(items.map((e) => e.$2));
    if (pi < pages.length - 1) blocks.add(const DocPageBreak());
  }
  return DocBuildResult(DocModel(blocks, header: running.header, footer: running.footer, pageWidth: first.width, pageHeight: first.height, title: title), warnings);
}

// ---------------------------------------------------------------------------
// Other text formats
// ---------------------------------------------------------------------------

String htmlEscape(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

/// Semantic HTML (headings, paragraphs, lists, tables, embedded images).
String docToHtml(DocModel m) {
  final sb = StringBuffer('<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>${htmlEscape(m.title.isEmpty ? 'Document' : m.title)}</title>'
      '<style>body{font-family:Arial,Helvetica,sans-serif;max-width:860px;margin:2em auto;padding:0 1em;line-height:1.45}'
      'table{border-collapse:collapse;margin:1em 0}td,th{border:1px solid #999;padding:4px 8px}th{background:#eee}img{max-width:100%}'
      '.page-break{border:0;border-top:1px dashed #bbb;margin:2em 0}.uncertain{background:#fff2cc}</style></head><body>\n');
  if (m.header.isNotEmpty) sb.writeln('<header>${htmlEscape(m.header)}</header>');
  var inHeading = false;
  String runs(List<DocRun> rs) => rs.map((r) {
        var t = htmlEscape(r.text).replaceAll('\n', '<br>');
        final style = [
          if (r.color != null && (r.color! & 0xFFFFFF) != 0) 'color:#${(r.color! & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        ].join(';');
        if (r.bold && !inHeading) t = '<strong>$t</strong>';
        if (r.italic) t = '<em>$t</em>';
        if (r.underline) t = '<u>$t</u>';
        if (style.isNotEmpty) t = '<span style="$style">$t</span>';
        if (r.link != null) t = '<a href="${htmlEscape(r.link!)}">$t</a>';
        return t;
      }).join();
  String? openList;
  void closeList() {
    if (openList != null) sb.writeln('</$openList>');
    openList = null;
  }

  for (final b in m.blocks) {
    if (b is DocParagraph && (b.style == ParaStyle.bullet || b.style == ParaStyle.numbered)) {
      final tag = b.style == ParaStyle.bullet ? 'ul' : 'ol';
      if (openList != tag) {
        closeList();
        sb.writeln('<$tag>');
        openList = tag;
      }
      sb.writeln('<li>${runs(b.runs)}</li>');
      continue;
    }
    closeList();
    switch (b) {
      case DocParagraph p:
        final tag = switch (p.style) { ParaStyle.title || ParaStyle.h1 => 'h1', ParaStyle.h2 => 'h2', ParaStyle.h3 => 'h3', _ => 'p' };
        final align = p.align == ParaAlign.left ? '' : ' style="text-align:${p.align.name}"';
        inHeading = tag != 'p';
        if (!p.isEmpty) sb.writeln('<$tag$align>${runs(p.runs)}</$tag>');
        inHeading = false;
      case DocTable t:
        sb.writeln('<table>');
        for (var i = 0; i < t.rows.length; i++) {
          final cell = i == 0 && t.headerRow ? 'th' : 'td';
          sb.writeln('<tr>${t.rows[i].map((c) => '<$cell${c.uncertain ? ' class="uncertain"' : ''}>${htmlEscape(c.text)}</$cell>').join()}</tr>');
        }
        sb.writeln('</table>');
      case DocImage img:
        sb.writeln('<p><img alt="" width="${img.width.round()}" src="data:image/${img.isJpeg ? 'jpeg' : 'png'};base64,${base64Encode(img.bytes)}"></p>');
      case DocPageBreak _:
        sb.writeln('<hr class="page-break">');
    }
  }
  closeList();
  if (m.footer.isNotEmpty) sb.writeln('<footer>${htmlEscape(m.footer)}</footer>');
  sb.write('</body></html>\n');
  return sb.toString();
}

/// Plain text, page by page, keeping line breaks.
String pagesToText(List<PageContent> pages) {
  final sb = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    if (i > 0) sb.write('\n\f\n');
    for (final l in readingOrder(pages[i])) {
      sb.writeln(l.text);
    }
  }
  return sb.toString();
}

/// RFC 4180 CSV of a table.
String tableToCsv(List<List<String>> rows) {
  String q(String s) => RegExp(r'[",\r\n]').hasMatch(s) || s.startsWith(' ') || s.endsWith(' ') ? '"${s.replaceAll('"', '""')}"' : s;
  return rows.map((r) => r.map(q).join(',')).join('\r\n');
}

// ---------------------------------------------------------------------------
// PDF → PowerPoint
// ---------------------------------------------------------------------------

/// One slide per page: editable text boxes, pictures and tables at their
/// positions, scaled to a 720-point-wide slide. Pages with no extractable
/// text (scans) become picture slides and are reported in [imageSlides].
({PresentationModel deck, List<int> imageSlides}) pagesToEditableSlides(List<PageContent> pages, {String title = '', Map<int, ({Uint8List bytes})>? pageImages}) {
  final first = pages.first.size;
  const slideW = 720.0;
  final slideH = (slideW * first.height / first.width).clamp(72.0, 4032.0);
  final slides = <SlideModel>[];
  final imageSlides = <int>[];
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    final k = math.min(slideW / p.size.width, slideH / p.size.height);
    Rect sc(Rect r) => Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k);
    final shapes = <SlideShape>[];
    if (!p.hasText && pageImages?[p.index] != null) {
      shapes.add(SlidePicture(Rect.fromLTWH(0, 0, p.size.width * k, p.size.height * k), pageImages![p.index]!.bytes, label: 'Page ${p.index + 1} (image)'));
      imageSlides.add(i + 1);
      slides.add(SlideModel(shapes));
      continue;
    }
    for (final img in p.images) {
      shapes.add(SlidePicture(sc(img.box), img.png));
    }
    final tables = const TableExtractionService().extract(p);
    for (final t in tables) {
      shapes.add(SlideTable(sc(t.bounds), [for (final r in t.rows) [for (final c in r) c.text]], header: t.headerRow));
    }
    // Text boxes: consecutive lines with the same left edge and style.
    final lines = p.lines.where((l) => !tables.any((t) => t.bounds.inflate(2).contains(l.box.center))).toList();
    var group = <PdfLine>[];
    void flush() {
      if (group.isEmpty) return;
      final box = group.map((l) => l.box).reduce((a, b) => a.expandToInclude(b));
      final paras = [
        for (final l in group)
          SlideParagraph([
            for (final w in l.words) DocRun('${w.text} ', bold: w.bold, italic: w.italic, size: (w.size * k * 2).round() / 2, color: w.color, font: officeFontFor(w.font)),
          ])
      ];
      final isTitle = group.length <= 2 && group.first.size >= 16;
      shapes.add(SlideText(sc(box.inflate(1)), paras, title: isTitle && shapes.whereType<SlideText>().isEmpty));
      group = [];
    }

    for (final l in lines) {
      if (group.isNotEmpty) {
        final prev = group.last;
        final close = l.box.top - prev.box.bottom < prev.size * 1.2 && (l.box.left - group.first.box.left).abs() < prev.size * 2 && (l.size - prev.size).abs() < prev.size * 0.2;
        if (!close) flush();
      }
      group.add(l);
    }
    flush();
    slides.add(SlideModel(shapes));
  }
  return (deck: PresentationModel(slides, width: slideW, height: slideH, title: title), imageSlides: imageSlides);
}
