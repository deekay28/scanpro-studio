import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../../convert/model/doc_model.dart';
import '../../convert/model/page_content.dart';

enum ChangeKind { inserted, deleted, changed }

class TextChange {
  final ChangeKind kind;
  final String oldText;
  final String newText;
  final int? oldPage; // 0-based
  final int? newPage;
  final List<Rect> oldRects;
  final List<Rect> newRects;
  final bool numeric; // a changed number/amount
  const TextChange(this.kind, this.oldText, this.newText, this.oldPage, this.newPage, this.oldRects, this.newRects, {this.numeric = false});
}

class VisualChange {
  final int page;
  final double ratio; // fraction of the page that differs
  final List<Rect> regions; // display points
  const VisualChange(this.page, this.ratio, this.regions);
}

class ComparisonResult {
  final List<TextChange> changes;
  final List<String> structure; // page count / size differences
  final List<VisualChange> visual;
  final int oldWords;
  final int newWords;
  final bool approximate; // very large difference: compared page by page
  const ComparisonResult(this.changes, this.structure, this.visual, this.oldWords, this.newWords, {this.approximate = false});
  bool get identical => changes.isEmpty && structure.isEmpty && visual.isEmpty;
}

class _Tok {
  final String key;
  final String text;
  final int page;
  final Rect box;
  const _Tok(this.key, this.text, this.page, this.box);
}

List<_Tok> _tokens(List<PageContent> pages) {
  final out = <_Tok>[];
  for (final p in pages) {
    final lines = p.lines;
    var carry = false; // the first word of this line was joined to the previous line
    for (var li = 0; li < lines.length; li++) {
      final words = lines[li].words;
      final skip = carry;
      carry = false;
      for (var wi = skip ? 1 : 0; wi < words.length; wi++) {
        final w = words[wi];
        final text = w.text;
        // Re-join words hyphenated across a line break.
        if (wi == words.length - 1 && text.endsWith('-') && text.length > 1 && li + 1 < lines.length && lines[li + 1].words.isNotEmpty) {
          final next = lines[li + 1].words.first;
          if (RegExp(r'^[a-z]').hasMatch(next.text)) {
            final joined = text.substring(0, text.length - 1) + next.text;
            out.add(_Tok(_key(joined), joined, p.index, w.box.expandToInclude(next.box)));
            carry = true;
            continue;
          }
        }
        out.add(_Tok(_key(text), text, p.index, w.box));
      }
    }
  }
  return out;
}

String _key(String s) => s.replaceAll(RegExp(r'[‘’]'), "'").replaceAll(RegExp(r'[“”]'), '"').replaceAll(RegExp(r'[–—]'), '-');

/// Myers diff on token keys. Returns the edit script as (op, i, j) where op
/// is 0 equal, 1 delete a[i], 2 insert b[j]; or null when the edit distance
/// exceeds [maxD].
List<(int, int, int)>? _myers(List<String> a, List<String> b, {int maxD = 3000}) {
  final n = a.length, m = b.length;
  final max = n + m;
  final offset = max + 1;
  final v = List<int>.filled(2 * max + 3, 0);
  // Only the diagonals -d..d are relevant at step d, so each trace entry
  // stores that window (memory grows with d², not with document size).
  final trace = <List<int>>[];
  for (var d = 0; d <= math.min(max, maxD); d++) {
    trace.add(v.sublist(math.max(0, offset - d - 1), math.min(v.length, offset + d + 2)));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        final ops = <(int, int, int)>[];
        var cx = n, cy = m;
        for (var dd = d; dd > 0; dd--) {
          final pv = trace[dd];
          final base = math.max(0, offset - dd - 1);
          int at(int kk) => pv[offset + kk - base];
          final kk = cx - cy;
          final prevK = (kk == -dd || (kk != dd && at(kk - 1) < at(kk + 1))) ? kk + 1 : kk - 1;
          final prevX = at(prevK);
          final prevY = prevX - prevK;
          while (cx > prevX && cy > prevY) {
            ops.add((0, cx - 1, cy - 1));
            cx--;
            cy--;
          }
          if (cx == prevX) {
            ops.add((2, cx, cy - 1));
          } else {
            ops.add((1, cx - 1, cy));
          }
          cx = prevX;
          cy = prevY;
        }
        while (cx > 0 && cy > 0) {
          ops.add((0, cx - 1, cy - 1));
          cx--;
          cy--;
        }
        return ops.reversed.toList();
      }
    }
  }
  return null;
}

final _num = RegExp(r'^[-+(]?[₹$€£]?\d[\d,.\s]*%?\)?$');

/// Text comparison of two documents (word level, with positions) plus
/// page structure. Rendering-only differences (fonts, compression) do not
/// produce text changes because only extracted text is compared.
ComparisonResult compareText(List<PageContent> oldPages, List<PageContent> newPages) {
  final structure = <String>[];
  if (oldPages.length != newPages.length) structure.add('Page count: ${oldPages.length} → ${newPages.length}.');
  for (var i = 0; i < math.min(oldPages.length, newPages.length); i++) {
    final a = oldPages[i].size, b = newPages[i].size;
    if ((a.width - b.width).abs() > 1 || (a.height - b.height).abs() > 1) {
      structure.add('Page ${i + 1} size: ${a.width.round()}×${a.height.round()} → ${b.width.round()}×${b.height.round()} pt.');
    }
  }
  final ta = _tokens(oldPages), tb = _tokens(newPages);
  var ops = _myers([for (final t in ta) t.key], [for (final t in tb) t.key]);
  var approximate = false;
  if (ops == null) {
    // Very different documents: compare page by page to bound the work.
    approximate = true;
    ops = [];
    var ia = 0, ib = 0;
    for (var p = 0; p < math.max(oldPages.length, newPages.length); p++) {
      final pa = [for (var i = ia; i < ta.length && ta[i].page == p; i++) ta[i].key];
      final pb = [for (var i = ib; i < tb.length && tb[i].page == p; i++) tb[i].key];
      final sub = _myers(pa, pb, maxD: pa.length + pb.length) ?? const <(int, int, int)>[];
      ops.addAll(sub.map((o) => (o.$1, o.$2 + ia, o.$3 + ib)));
      ia += pa.length;
      ib += pb.length;
    }
  }
  // Group consecutive non-equal ops into changes.
  final changes = <TextChange>[];
  var i = 0;
  while (i < ops.length) {
    if (ops[i].$1 == 0) {
      i++;
      continue;
    }
    final del = <_Tok>[], ins = <_Tok>[];
    while (i < ops.length && ops[i].$1 != 0) {
      if (ops[i].$1 == 1) {
        del.add(ta[ops[i].$2]);
      } else {
        ins.add(tb[ops[i].$3]);
      }
      i++;
    }
    final kind = del.isEmpty ? ChangeKind.inserted : (ins.isEmpty ? ChangeKind.deleted : ChangeKind.changed);
    final oldText = del.map((t) => t.text).join(' '), newText = ins.map((t) => t.text).join(' ');
    changes.add(TextChange(kind, oldText, newText, del.isEmpty ? null : del.first.page, ins.isEmpty ? null : ins.first.page, [for (final t in del) t.box], [for (final t in ins) t.box],
        numeric: kind == ChangeKind.changed && _num.hasMatch(oldText) && _num.hasMatch(newText)));
  }
  return ComparisonResult(changes, structure, const [], ta.length, tb.length, approximate: approximate);
}

/// Visual comparison of two renders of the same size (RGBA). Differences
/// can come from content changes but also from compression or font
/// rendering, so results are reported as "visual differences".
VisualChange? compareRender(int page, Uint8List a, Uint8List b, int width, int height, {double pointsPerPixel = 1, int cell = 12, int threshold = 60}) {
  final cols = (width / cell).ceil(), rows = (height / cell).ceil();
  final hot = List<bool>.filled(cols * rows, false);
  var diffPx = 0;
  for (var cy = 0; cy < rows; cy++) {
    for (var cx = 0; cx < cols; cx++) {
      var count = 0, total = 0;
      for (var y = cy * cell; y < math.min(height, (cy + 1) * cell); y++) {
        for (var x = cx * cell; x < math.min(width, (cx + 1) * cell); x++) {
          final i = (y * width + x) * 4;
          final la = a[i] * 3 + a[i + 1] * 6 + a[i + 2];
          final lb = b[i] * 3 + b[i + 1] * 6 + b[i + 2];
          if ((la - lb).abs() > threshold * 10) count++;
          total++;
        }
      }
      if (count > total * 0.08) {
        hot[cy * cols + cx] = true;
        diffPx += count;
      }
    }
  }
  if (diffPx == 0) return null;
  // Merge hot cells into rectangles (flood fill).
  final seen = List<bool>.filled(cols * rows, false);
  final regions = <Rect>[];
  for (var i = 0; i < hot.length; i++) {
    if (!hot[i] || seen[i]) continue;
    var minX = cols, minY = rows, maxX = 0, maxY = 0;
    final stack = [i];
    seen[i] = true;
    while (stack.isNotEmpty) {
      final c = stack.removeLast();
      final x = c % cols, y = c ~/ cols;
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
        final n = ny * cols + nx;
        if (hot[n] && !seen[n]) {
          seen[n] = true;
          stack.add(n);
        }
      }
    }
    regions.add(Rect.fromLTRB(minX * cell * pointsPerPixel, minY * cell * pointsPerPixel, (maxX + 1) * cell * pointsPerPixel, (maxY + 1) * cell * pointsPerPixel));
  }
  return VisualChange(page, diffPx / (width * height), regions);
}

/// A readable report of the comparison.
DocModel comparisonReport(ComparisonResult r, String oldName, String newName) {
  final blocks = <DocBlock>[
    const DocParagraph([DocRun('Document comparison')], style: ParaStyle.title),
    DocParagraph([const DocRun('Original: ', bold: true), DocRun(oldName)]),
    DocParagraph([const DocRun('Revised: ', bold: true), DocRun(newName)]),
    DocParagraph([
      DocRun(r.identical ? 'No differences found in the text or page structure.' : '${r.changes.length} text change(s); ${r.structure.length} structural difference(s); ${r.visual.length} page(s) with visual differences.'),
    ]),
    if (r.approximate) const DocParagraph([DocRun('The documents differ a lot; they were compared page by page.', italic: true)]),
  ];
  if (r.structure.isNotEmpty) {
    blocks.add(const DocParagraph([DocRun('Structure')], style: ParaStyle.h2));
    blocks.addAll(r.structure.map((s) => DocParagraph([DocRun(s)], style: ParaStyle.bullet)));
  }
  if (r.changes.isNotEmpty) {
    blocks.add(const DocParagraph([DocRun('Text changes')], style: ParaStyle.h2));
    blocks.add(DocTable([
      const [DocTableCell('Page'), DocTableCell('Change'), DocTableCell('Original'), DocTableCell('Revised')],
      for (final c in r.changes.take(2000))
        [
          DocTableCell('${(c.newPage ?? c.oldPage ?? 0) + 1}'),
          DocTableCell(c.numeric ? 'Value changed' : switch (c.kind) { ChangeKind.inserted => 'Inserted', ChangeKind.deleted => 'Deleted', ChangeKind.changed => 'Changed' }),
          DocTableCell(c.oldText),
          DocTableCell(c.newText),
        ]
    ], headerRow: true, columnWidths: const [40, 80, 200, 200]));
  }
  if (r.visual.isNotEmpty) {
    blocks.add(const DocParagraph([DocRun('Visual differences')], style: ParaStyle.h2));
    blocks.add(const DocParagraph([DocRun('These pages look different. This can be a real change (for example in a scan) or only compression or font rendering.', italic: true)]));
    blocks.addAll(r.visual.map((v) => DocParagraph([DocRun('Page ${v.page + 1}: ${(v.ratio * 100).toStringAsFixed(1)}% of the page, ${v.regions.length} area(s)')], style: ParaStyle.bullet)));
  }
  return DocModel(blocks, title: 'Comparison of $oldName and $newName');
}
