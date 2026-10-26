import '../model/edit_state.dart';

/// A positioned piece of text: one line, or one word for justified lines.
class LaidOutRun {
  final String text;
  final double x; // offset from the box's left edge (points)
  final int line; // line number from 0
  const LaidOutRun(this.text, this.x, this.line);
}

class TextLayoutResult {
  final List<LaidOutRun> runs;
  final int lineCount;
  final double maxLineWidth;
  final bool overflowedWidth; // a single word is wider than the box
  const TextLayoutResult(this.runs, this.lineCount, this.maxLineWidth, this.overflowedWidth);
}

/// Greedy line breaking with alignment. [measure] returns the advance width
/// of a string in points at the font size being laid out. Explicit '\n'
/// characters start new paragraphs.
TextLayoutResult layoutText(String text, double width, TextAlign2 align, double Function(String) measure) {
  final runs = <LaidOutRun>[];
  var line = 0;
  var maxW = 0.0;
  var overflow = false;
  final space = measure(' ');
  for (final para in text.split('\n')) {
    final words = para.split(RegExp(r'[ \t]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      line++;
      continue;
    }
    final lines = <List<String>>[];
    var cur = <String>[];
    var curW = 0.0;
    for (final w in words) {
      final ww = measure(w);
      if (ww > width) overflow = true;
      final add = cur.isEmpty ? ww : curW + space + ww;
      if (cur.isNotEmpty && add > width + 0.01) {
        lines.add(cur);
        cur = [w];
        curW = ww;
      } else {
        cur.add(w);
        curW = add;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    for (var li = 0; li < lines.length; li++) {
      final ws = lines[li];
      final s = ws.join(' ');
      final lw = measure(s);
      if (lw > maxW) maxW = lw;
      final last = li == lines.length - 1;
      if (align == TextAlign2.justify && !last && ws.length > 1) {
        final wordsW = ws.fold<double>(0, (a, w) => a + measure(w));
        final gap = (width - wordsW) / (ws.length - 1);
        var x = 0.0;
        for (final w in ws) {
          runs.add(LaidOutRun(w, x, line));
          x += measure(w) + gap;
        }
      } else {
        final x = switch (align) {
          TextAlign2.center => (width - lw) / 2,
          TextAlign2.right => width - lw,
          _ => 0.0,
        };
        runs.add(LaidOutRun(s, x < 0 ? 0 : x, line));
      }
      line++;
    }
  }
  return TextLayoutResult(runs, line, maxW, overflow);
}
