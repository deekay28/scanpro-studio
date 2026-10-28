import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../model/page_content.dart' show PdfWord;
import 'layout_model.dart' show median, textAdvance;

/// OCR engines differ a lot in how exact their word boxes are: tesseract
/// boxes fit the ink, ML Kit boxes are padded, sometimes only whole lines
/// are boxed and split evenly. Layout must not depend on that, so word
/// geometry is taken from the ink of the page itself; OCR only supplies the
/// text and roughly where it is.
///
/// 1. Long thin horizontal and vertical strokes (underlines, table borders)
///    are removed so letters touching them become separate.
/// 2. The remaining ink is split into connected components, which are
///    assigned to the OCR line whose band they sit in.
/// 3. Along each line, components that overlap horizontally form glyph
///    clusters; the OCR words are cut at the gaps between clusters that best
///    match the OCR word boundaries (preferring wide gaps).
/// 4. Each word's box becomes the union of its clusters.
///
/// Words with no ink of their own (noise read on a stamp, a signature or the
/// paper) are dropped, and so are words whose ink is clearly lighter or more
/// coloured than the page's printed text (text printed in a stamp): they are
/// part of a picture, not of the text.
class InkGeometry {
  final Uint8List ink, norm, colored;
  final int w, h;
  InkGeometry(this.ink, this.norm, this.colored, this.w, this.h, {this.log});
  final void Function(String)? log;

  double body = 0;
  Uint8List _mask = Uint8List(0);
  bool _faint(_Comp c) => c.n >= 6 && (c.meanLevel > body + 38 || c.coloredShare > 0.45);

  /// Words dropped as stamp text or noise (for the review report).
  final dropped = <PdfWord>[];

  List<PdfWord> snap(List<PdfWord> input) {
    var words = input;
    if (words.isEmpty) return words;
    var hs = words.map((x) => x.box.height).toList()..sort();
    final typical = hs[hs.length ~/ 2];
    hs = [];
    final mask = _mask = withoutStrokes(math.max(12, (typical * 2.6).round()));
    var comps = _components(mask, maxH: typical * 3);
    // Pieces of ruling lines shorter than the stroke limit (cell borders,
    // short underlines) are not letters: thin and long compared with the
    // page's letters.
    final letterH = median([for (final c in comps) if (c.n >= 8) c.height.toDouble()]);
    if (letterH > 0) {
      comps = comps.where((c) {
        final cw = c.x1 - c.x0 + 1, ch = c.height;
        if (ch > letterH * 1.7 && cw < ch * 0.22) return false;
        if (cw > letterH * 3.5 && ch < cw * 0.15) return false;
        return true;
      }).toList();
    }
    // The page's printed ink level; lighter or coloured marks (stamps, paper
    // edge shadows) are not letters of the text.
    body = median([for (final c in comps) if (c.n >= 12) c.meanLevel]);
    final grid = _Grid(comps, w, h);
    // A "word" several lines tall is OCR noise on a picture (signature,
    // seal) unless the ink inside it is one row of letters (a badly boxed
    // word).
    words = words.where((x) {
      if (x.box.height <= typical * 2.6) return true;
      final inside = grid.near(x.box).where((c) => x.box.contains(c.center)).toList();
      if (inside.isNotEmpty) {
        final ht = inside.map((c) => c.height.toDouble()).toList()..sort();
        final top = inside.map((c) => c.y0).reduce(math.min), bottom = inside.map((c) => c.y1).reduce(math.max);
        if (bottom - top + 1 <= ht[(ht.length * 0.75).floor().clamp(0, ht.length - 1)] * 1.6) return true;
      }
      dropped.add(x);
      return false;
    }).toList();
    // Where each word's own ink is (OCR boxes may be padded or offset):
    // components whose centre is inside the box.
    final anchors = <PdfWord, _Anchor>{};
    for (final wd in words) {
      final b = wd.box.inflate(wd.box.height * 0.1);
      final inside = grid.near(b).where((c) => b.contains(c.center)).toList();
      if (inside.isEmpty) {
        anchors[wd] = _Anchor(wd.box.center.dy, wd.box.height * 0.6, wd.box);
        continue;
      }
      final cys = inside.map((c) => c.center.dy).toList()..sort();
      final hts = inside.map((c) => c.height.toDouble()).toList()..sort();
      final u = inside.reduce((a, c) => _Comp.copy(a)..merge(c));
      anchors[wd] = _Anchor(cys[cys.length ~/ 2], hts[(hts.length * 0.75).floor().clamp(0, hts.length - 1)], Rect.fromLTRB(u.x0.toDouble(), u.y0.toDouble(), u.x1 + 1.0, u.y1 + 1.0));
    }
    final lines = _lines(words, anchors);
    // Components → the line of the nearest word (by its ink centre).
    final perLine = List.generate(lines.length, (_) => <_Comp>[]);
    final lineOf = <PdfWord, int>{for (var i = 0; i < lines.length; i++) for (final wd in lines[i]) wd: i};
    final wordGrid = <PdfWord>[...words];
    // Letter height per line (punctuation alone has tiny components).
    final lineCap = [
      for (final l in lines)
        () {
          final v = [for (final wd in l) if (wd.text.replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097F]'), '').length >= 2) anchors[wd]!.capH];
          return v.isEmpty ? median(l.map((wd) => anchors[wd]!.capH)) : median(v);
        }(),
    ];
    for (final c in comps) {
      final cc = c.center;
      var best = -1;
      var bestD = double.infinity;
      for (final wd in wordGrid) {
        final a = anchors[wd]!;
        final cap = math.max(a.capH, lineCap[lineOf[wd]!]);
        // Generous: ink beyond the OCR boxes is trimmed per word-sized run in
        // _snapLine and left for the second OCR pass.
        final reachX = cap * 3;
        if (cc.dx < math.min(wd.box.left, a.ink.left) - reachX || cc.dx > math.max(wd.box.right, a.ink.right) + reachX) continue;
        final dy = (cc.dy - a.cy).abs();
        if (dy > cap * 0.75 || c.height > cap * 2.4) continue;
        final dx = cc.dx < wd.box.left ? wd.box.left - cc.dx : (cc.dx > wd.box.right ? cc.dx - wd.box.right : 0.0);
        final d = dy + dx * 0.5;
        if (d < bestD) {
          bestD = d;
          best = lineOf[wd]!;
        }
      }
      if (best >= 0) perLine[best].add(c);
    }
    final out = <PdfWord>[];
    for (var i = 0; i < lines.length; i++) {
      log?.call('line ${lines[i].map((x) => '${x.text}@${x.box.left.round()},${x.box.top.round()},${x.box.width.round()}x${x.box.height.round()}').join(' ')} comps=${perLine[i].length}');
      out.addAll(_snapLine(lines[i], perLine[i]));
    }
    return _dedupe(_dropFaint(out));
  }

  /// The same ink read twice (first and second OCR pass, or overlapping
  /// OCR lines): the more confident reading stays.
  List<PdfWord> _dedupe(List<PdfWord> words) {
    final order = [...words]..sort((a, b) => (b.confidence ?? 0.8).compareTo(a.confidence ?? 0.8));
    final kept = <PdfWord>[];
    for (final wd in order) {
      final dup = kept.any((k) {
        final i = k.box.intersect(wd.box);
        if (i.width <= 0 || i.height <= 0) return false;
        final small = math.min(k.box.width * k.box.height, wd.box.width * wd.box.height);
        return i.width * i.height > small * 0.5;
      });
      if (dup) {
        dropped.add(wd);
      } else {
        kept.add(wd);
      }
    }
    return words.where(kept.contains).toList();
  }

  // ---- strokes ------------------------------------------------------------

  /// [ink] without horizontal or vertical runs longer than [len] pixels
  /// (ruling lines and underlines), keeping the strokes of letters.
  Uint8List withoutStrokes(int len) {
    final m = Uint8List.fromList(ink);
    for (var y = 0; y < h; y++) {
      var x = 0;
      while (x < w) {
        if (ink[y * w + x] == 0) {
          x++;
          continue;
        }
        final s = x;
        while (x < w && ink[y * w + x] == 1) {
          x++;
        }
        if (x - s > len) m.fillRange(y * w + s, y * w + x, 0);
      }
    }
    for (var x = 0; x < w; x++) {
      var y = 0;
      while (y < h) {
        if (ink[y * w + x] == 0) {
          y++;
          continue;
        }
        final s = y;
        while (y < h && ink[y * w + x] == 1) {
          y++;
        }
        if (y - s > len) {
          for (var yy = s; yy < y; yy++) {
            m[yy * w + x] = 0;
          }
        }
      }
    }
    return m;
  }

  List<_Comp> _components(Uint8List m, {required double maxH}) {
    final label = Int32List(w * h);
    final out = <_Comp>[];
    final stack = <int>[];
    for (var i = 0; i < w * h; i++) {
      if (m[i] == 0 || label[i] != 0) continue;
      final c = _Comp(i % w, i ~/ w);
      label[i] = 1;
      stack.add(i);
      while (stack.isNotEmpty) {
        final k = stack.removeLast();
        final x = k % w, y = k ~/ w;
        c.add(x, y, norm[k], colored[k]);
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            final j = yy * w + xx;
            if (m[j] == 1 && label[j] == 0) {
              label[j] = 1;
              stack.add(j);
            }
          }
        }
      }
      if (c.n >= 2 && c.height <= maxH) out.add(c);
    }
    return out;
  }

  // ---- lines --------------------------------------------------------------

  /// OCR words grouped into lines: vertically overlapping, left to right.
  List<List<PdfWord>> _lines(List<PdfWord> words, Map<PdfWord, _Anchor> anchors) {
    final sorted = [...words]..sort((a, b) => a.box.left.compareTo(b.box.left));
    // The engine's own lines when it reports them.
    if (words.every((x) => x.line != null)) {
      final by = <int, List<PdfWord>>{};
      for (final wd in sorted) {
        (by[wd.line!] ??= []).add(wd);
      }
      return by.values.toList();
    }
    final lines = <List<PdfWord>>[];
    for (final wd in sorted) {
      final aw = anchors[wd]!;
      List<PdfWord>? best;
      var bestD = double.infinity;
      for (final l in lines) {
        final last = l.last;
        final al = anchors[last]!;
        if (wd.box.left < last.box.left + last.box.width * 0.5) continue;
        if (wd.box.left - last.box.right > math.max(al.capH, aw.capH) * 8) continue;
        // Ink centres on one line differ by much less than a line pitch.
        final d = (aw.cy - al.cy).abs() / math.max(al.capH, aw.capH);
        if (d < 0.45 && d < bestD) {
          best = l;
          bestD = d;
        }
      }
      if (best == null) {
        lines.add([wd]);
      } else {
        best.add(wd);
      }
    }
    return lines;
  }

  List<PdfWord> _snapLine(List<PdfWord> ws, List<_Comp> comps) {
    if (comps.isEmpty) {
      for (final wd in ws) {
        if ((wd.confidence ?? 0.8) >= 0.9) continue;
        dropped.add(wd);
      }
      return [for (final wd in ws) if ((wd.confidence ?? 0.8) >= 0.9) wd];
    }
    // Glyph clusters: components overlapping horizontally (i and its dot,
    // the two dots of a colon, accents).
    comps.sort((a, b) => a.x0.compareTo(b.x0));
    final clusters = <_Comp>[];
    for (final c in comps) {
      if (clusters.isNotEmpty && c.x0 <= clusters.last.x1 - 1) {
        clusters.last.merge(c);
      } else {
        clusters.add(_Comp.copy(c));
      }
    }
    final ch = [for (final c in clusters) c.height.toDouble()]..sort();
    final capH = math.max(4.0, ch[(ch.length * 0.75).floor().clamp(0, ch.length - 1)]);
    clusters.removeWhere(_faint);
    if (clusters.isEmpty) {
      dropped.addAll(ws);
      return const [];
    }
    // Punctuation OCR engines skip (ML Kit drops lone ":" and "/"): read
    // from the ink when its shape is unmistakable, and listed for review.
    // Baseline near each mark (a long line in a tilted photo isn't level).
    double baseNear(_Comp c) => median([
          for (final o in clusters)
            if (o.height >= capH * 0.6 && o.height <= capH * 1.1 && (o.center.dx - c.center.dx).abs() < capH * 5) o.y1.toDouble(),
        ]);
    final synth = <PdfWord>[];
    for (var i = clusters.length - 1; i >= 0; i--) {
      final c = clusters[i];
      final mark = _colon(c, capH, baseNear(c)) ? ':' : (_slash(c, capH) ? '/' : null);
      if (mark == null) continue;
      final gl = i > 0 ? c.x0 - clusters[i - 1].x1 - 1 : 1 << 20, gr = i < clusters.length - 1 ? clusters[i + 1].x0 - c.x1 - 1 : 1 << 20;
      // Read already: as this mark, or as some other short mark (OCR
      // misreading ":" as "+" is kept as read, never doubled).
      final read = ws.any((wd) =>
          (wd.text.contains(mark) && wd.box.right >= c.x0 - capH * 0.3 && wd.box.left <= c.x1 + capH * 0.3) ||
          (wd.text.length <= 2 && !RegExp(r'[A-Za-z0-9\u0900-\u097F]').hasMatch(wd.text) && wd.box.right >= c.x0 && wd.box.left <= c.x1));
      if (read || math.min(gl, gr) < capH * 0.2) continue;
      synth.add(PdfWord(mark, Rect.fromLTRB(c.x0.toDouble(), c.y0.toDouble(), c.x1 + 1.0, c.y1 + 1.0), confidence: 0.59, line: ws.first.line)..ink = c);
      clusters.removeAt(i);
    }
    if (clusters.isEmpty) {
      dropped.addAll(ws);
      return synth;
    }
    // Specks and hairlines (remains of a cell border) far from any letter
    // would look like words.
    final thinText = ws.any((x) => RegExp(r'^[1lI|!:;.,]+$').hasMatch(x.text));
    for (var i = clusters.length - 1; i >= 0 && clusters.length > 1; i--) {
      final c = clusters[i];
      final cw = c.x1 - c.x0 + 1;
      final speck = c.height <= capH * 0.3 && cw <= capH * 0.3;
      final hairline = cw <= capH * 0.2 && !thinText;
      if (!speck && !hairline) continue;
      final gl = i > 0 ? c.x0 - clusters[i - 1].x1 : 1 << 20, gr = i < clusters.length - 1 ? clusters[i + 1].x0 - c.x1 : 1 << 20;
      if (math.min(gl, gr) > capH * 0.8) clusters.removeAt(i);
    }
    // Ink at the ends of the line that is set apart by a word gap and lies
    // outside every OCR box (paper edge shadow, a mark) isn't text.
    // Runs of clusters separated by word gaps (a space is about 0.39 of the
    // cap height in Arial, letter gaps under 0.15); leading and trailing runs
    // that no OCR box reaches are left for the second OCR pass.
    final runs = <List<_Comp>>[
      [clusters.first],
    ];
    for (var i = 1; i < clusters.length; i++) {
      if (clusters[i].x0 - clusters[i - 1].x1 - 1 > capH * 0.27) {
        runs.add([clusters[i]]);
      } else {
        runs.last.add(clusters[i]);
      }
    }
    bool reached(List<_Comp> r) {
      final a = r.first.x0, b = r.map((c) => c.x1).reduce(math.max);
      var ov = 0.0;
      for (final wd in ws) {
        ov += math.max(0, math.min(b + 1.0, wd.box.right) - math.max(a.toDouble(), wd.box.left));
      }
      return ov > (b - a + 1) * 0.3;
    }

    while (runs.length > 1 && !reached(runs.first)) {
      runs.removeAt(0);
    }
    while (runs.length > 1 && !reached(runs.last)) {
      runs.removeLast();
    }
    clusters
      ..clear()
      ..addAll([for (final r in runs) ...r]);
    final k = ws.length;
    final n = clusters.length;
    final groups = List.generate(k, (_) => <_Comp>[]);
    if (k == 1) {
      groups[0].addAll(clusters);
    } else if (n < k) {
      // Fewer glyph groups than words: assign by the OCR boxes.
      for (final c in clusters) {
        final cx = (c.x0 + c.x1 + 1) / 2;
        var bi = 0;
        var bd = double.infinity;
        for (var j = 0; j < k; j++) {
          final b = ws[j].box;
          final d = cx < b.left ? b.left - cx : (cx > b.right ? cx - b.right : 0.0);
          if (d < bd) {
            bd = d;
            bi = j;
          }
        }
        groups[bi].add(c);
      }
    } else {
      // Cut positions: k-1 of the n-1 gaps, increasing, minimising distance
      // to the OCR boundaries and preferring wide gaps.
      final gx = [for (var i = 0; i < n - 1; i++) (clusters[i].x1 + 1 + clusters[i + 1].x0) / 2];
      final gw = [for (var i = 0; i < n - 1; i++) math.max(0, clusters[i + 1].x0 - clusters[i].x1 - 1).toDouble()];
      final bx = [for (var j = 0; j < k - 1; j++) (ws[j].box.right + ws[j + 1].box.left) / 2];
      // Word gaps in the ink count far more than where OCR put the boundary
      // (boxes split evenly along a line can be several words off).
      double cost(int j, int i) => (gx[i] - bx[j]).abs() / (capH * 4) - 3 * math.min(1.0, gw[i] / (capH * 0.35));
      final g = n - 1;
      final dp = List.generate(k - 1, (_) => List<double>.filled(g, double.infinity));
      final from = List.generate(k - 1, (_) => List<int>.filled(g, -1));
      for (var i = 0; i < g; i++) {
        dp[0][i] = cost(0, i);
      }
      for (var j = 1; j < k - 1; j++) {
        var bestPrev = double.infinity, bestI = -1;
        for (var i = 0; i < g; i++) {
          if (i > 0 && dp[j - 1][i - 1] < bestPrev) {
            bestPrev = dp[j - 1][i - 1];
            bestI = i - 1;
          }
          if (bestI >= 0) {
            dp[j][i] = bestPrev + cost(j, i);
            from[j][i] = bestI;
          }
        }
      }
      var end = -1;
      var endCost = double.infinity;
      for (var i = 0; i < g; i++) {
        if (dp[k - 2][i] < endCost) {
          endCost = dp[k - 2][i];
          end = i;
        }
      }
      final cuts = List<int>.filled(k - 1, 0);
      for (var j = k - 2; j >= 0; j--) {
        cuts[j] = end;
        end = from[j][end];
      }
      var j = 0;
      for (var i = 0; i < n; i++) {
        groups[j].add(clusters[i]);
        if (j < k - 1 && i == cuts[j]) j++;
      }
    }
    // Glyphs far beyond the first or last word belong to something else.
    final first = ws.first.box.left - capH * 1.2, last = ws.last.box.right + capH * 1.2;
    final out = <PdfWord>[];
    for (var j = 0; j < k; j++) {
      final wd = ws[j];
      var gs = groups[j].where((c) => c.x1 >= first && c.x0 <= last).toList();
      // Ink separated from the rest by a word-sized gap and outside the OCR
      // box (paper edge shadow, a border, a neighbour OCR didn't read) is
      // not part of this word.
      if (gs.length > 1) {
        final runs = <List<_Comp>>[
          [gs.first],
        ];
        for (var i = 1; i < gs.length; i++) {
          if (gs[i].x0 - gs[i - 1].x1 - 1 > capH * 0.27) {
            runs.add([gs[i]]);
          } else {
            runs.last.add(gs[i]);
          }
        }
        if (runs.length > 1) {
          double inBox(List<_Comp> r) {
            final a = r.first.x0.toDouble(), b = r.last.x1 + 1.0;
            final ov = math.min(b, wd.box.right) - math.max(a, wd.box.left);
            return ov / math.max(1, b - a);
          }

          final kept = [for (final r in runs) if (inBox(r) > 0.3) ...r];
          if (kept.isNotEmpty && kept.length < gs.length && inBox(gs) > 0.5) gs = kept;
        }
      }
      if (gs.isEmpty) {
        if ((wd.confidence ?? 0.8) >= 0.9) {
          out.add(wd);
        } else {
          dropped.add(wd);
        }
        continue;
      }
      final u = gs.reduce((a, b) => _Comp.copy(a)..merge(b));
      var text = wd.text;
      var conf = wd.confidence;
      // A slash between letters that OCR left out ("FacWing" for
      // "Fac/Wing"): put back where it is, and listed for review.
      if (!text.contains('/') && gs.length >= 2) {
        final total = textAdvance(text);
        final em = (u.x1 - u.x0 + 1) / math.max(0.1, total - 0.07); // pixels per em
        for (var i = 0; i < gs.length - 1; i++) {
          double p;
          if (_slash(gs[i], capH)) {
            // Also a word's first character ("/Debit").
            p = ((gs[i].x0 + gs[i].x1) / 2 - u.x0) / math.max(1, u.x1 - u.x0);
          } else if (i > 0 && _leadingSlash(gs[i], capH)) {
            // Slash touching the next letter: the cluster is wider than that
            // letter alone.
            final at0 = _charAt(text, (gs[i].x0 + capH * 0.2 - u.x0) / math.max(1, u.x1 - u.x0));
            if (at0 >= text.length || gs[i].width < textAdvance(text[at0]) * em + capH * 0.2) continue;
            p = (gs[i].x0 - u.x0) / math.max(1, u.x1 - u.x0);
          } else {
            continue;
          }
          var acc = 0.0, at = text.length;
          for (var c = 0; c < text.length; c++) {
            final adv = textAdvance(text[c]);
            if ((acc + adv / 2) / total > p) {
              at = c;
              break;
            }
            acc += adv;
          }
          if ((at == 0 && i > 0) || at == text.length) continue;
          text = '${text.substring(0, at)}/${text.substring(at)}';
          conf = math.min(conf ?? 0.8, 0.59);
          break;
        }
      }
      out.add(PdfWord(text, Rect.fromLTRB(u.x0.toDouble(), u.y0.toDouble(), u.x1 + 1.0, u.y1 + 1.0), confidence: conf, line: wd.line)..ink = u);
    }
    return [...out, ...synth];
  }

  /// Two small dots, one above the other, the lower one on the baseline.
  bool _colon(_Comp c, double capH, double base) =>
      c.parts == 2 &&
      c.maxPartH <= capH * 0.35 &&
      c.maxPartW <= capH * 0.35 &&
      c.height >= capH * 0.35 &&
      c.height <= capH * 0.9 &&
      c.maxPartH * 2 < c.height &&
      (c.y1 - base).abs() <= capH * 0.2;

  /// A straight stroke rising to the right, about a letter high: row by row
  /// the ink is narrow and its centre moves steadily right going up.
  bool _slash(_Comp c, double capH) {
    if (c.parts != 1 || c.height < capH * 0.8 || c.height > capH * 1.4 || c.width < capH * 0.15 || c.width > capH * 0.55) return false;
    final ys = <double>[], xs = <double>[];
    for (var y = c.y0; y <= c.y1; y++) {
      var sx = 0, n = 0, lo = 1 << 30, hi = -1;
      for (var x = c.x0; x <= c.x1; x++) {
        if (_mask[y * w + x] == 1) {
          sx += x;
          n++;
          lo = math.min(lo, x);
          hi = math.max(hi, x);
        }
      }
      if (n == 0) continue;
      if (hi - lo + 1 > c.width * 0.6) return false; // a bar (7, F, T)
      ys.add(y.toDouble());
      xs.add(sx / n);
    }
    if (ys.length < c.height * 0.8) return false;
    final my = ys.reduce((a, b) => a + b) / ys.length, mx = xs.reduce((a, b) => a + b) / xs.length;
    var sxy = 0.0, syy = 0.0;
    for (var i = 0; i < ys.length; i++) {
      sxy += (ys[i] - my) * (xs[i] - mx);
      syy += (ys[i] - my) * (ys[i] - my);
    }
    final slope = sxy / syy; // x per y (y grows downwards)
    var res = 0.0;
    for (var i = 0; i < ys.length; i++) {
      final d = xs[i] - (mx + slope * (ys[i] - my));
      res += d * d;
    }
    return slope < -0.15 && slope > -0.7 && math.sqrt(res / ys.length) <= c.width * 0.12;
  }

  /// Index of the character of [text] at fraction [p] of its width.
  static int _charAt(String text, double p) {
    final total = textAdvance(text);
    var acc = 0.0;
    for (var c = 0; c < text.length; c++) {
      acc += textAdvance(text[c]);
      if (acc / total > p) return c;
    }
    return text.length;
  }

  /// A cluster whose left edge is a straight stroke rising to the right
  /// over the full letter height: a slash joined to the letter after it.
  bool _leadingSlash(_Comp c, double capH) {
    if (c.height < capH * 0.8 || c.height > capH * 1.4 || c.width < capH * 0.7) return false;
    final ys = <double>[], xs = <double>[];
    for (var y = c.y0; y <= c.y1; y++) {
      for (var x = c.x0; x <= c.x1; x++) {
        if (_mask[y * w + x] == 1) {
          ys.add(y.toDouble());
          xs.add(x.toDouble());
          break;
        }
      }
    }
    if (ys.length < c.height * 0.85) return false;
    final my = ys.reduce((a, b) => a + b) / ys.length, mx = xs.reduce((a, b) => a + b) / xs.length;
    var sxy = 0.0, syy = 0.0;
    for (var i = 0; i < ys.length; i++) {
      sxy += (ys[i] - my) * (xs[i] - mx);
      syy += (ys[i] - my) * (ys[i] - my);
    }
    final slope = sxy / syy;
    var res = 0.0;
    for (var i = 0; i < ys.length; i++) {
      final d = xs[i] - (mx + slope * (ys[i] - my));
      res += d * d;
    }
    return slope < -0.15 && slope > -0.7 && math.sqrt(res / ys.length) <= capH * 0.06;
  }

  /// Drops words printed in a lighter or coloured ink than the page's text.
  List<PdfWord> _dropFaint(List<PdfWord> words) {
    if (body == 0) return words;
    return words.where((wd) {
      final c = wd.ink;
      if (c == null) return true;
      final light = c.meanLevel > body + 38;
      final tinted = c.coloredShare > 0.45;
      if (light || tinted) {
        log?.call('faint ${wd.text} level=${c.meanLevel.toStringAsFixed(0)} body=${body.toStringAsFixed(0)} col=${c.coloredShare.toStringAsFixed(2)} box=${wd.box}');
        dropped.add(wd);
        return false;
      }
      return true;
    }).toList();
  }
}

/// Bounding box and ink statistics of a connected group of ink pixels.
class _Anchor {
  final double cy, capH;
  final Rect ink;
  _Anchor(this.cy, this.capH, this.ink);
}

/// Components bucketed on a coarse grid for neighbourhood queries.
class _Grid {
  static const cell = 48;
  final int gw, gh;
  final List<List<_Comp>> buckets;
  _Grid(List<_Comp> comps, int w, int h)
      : gw = (w / cell).ceil() + 1,
        gh = (h / cell).ceil() + 1,
        buckets = List.generate(((w / cell).ceil() + 1) * ((h / cell).ceil() + 1), (_) => <_Comp>[]) {
    for (final c in comps) {
      final cc = c.center;
      buckets[(cc.dy ~/ cell).clamp(0, gh - 1) * gw + (cc.dx ~/ cell).clamp(0, gw - 1)].add(c);
    }
  }

  Iterable<_Comp> near(Rect r) sync* {
    final x0 = (r.left ~/ cell).clamp(0, gw - 1), x1 = (r.right ~/ cell).clamp(0, gw - 1);
    final y0 = (r.top ~/ cell).clamp(0, gh - 1), y1 = (r.bottom ~/ cell).clamp(0, gh - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        yield* buckets[y * gw + x];
      }
    }
  }
}

class _Comp {
  int x0, y0, x1, y1;
  int n = 0, levelSum = 0, coloredN = 0;
  int parts = 1; // connected components merged into this one
  int _partH = -1, _partW = -1; // size of the largest part (-1: this one)
  _Comp(int x, int y)
      : x0 = x,
        y0 = y,
        x1 = x,
        y1 = y;
  _Comp.copy(_Comp c)
      : x0 = c.x0,
        y0 = c.y0,
        x1 = c.x1,
        y1 = c.y1,
        n = c.n,
        levelSum = c.levelSum,
        coloredN = c.coloredN,
        parts = c.parts,
        _partH = c.maxPartH,
        _partW = c.maxPartW;

  int get width => x1 - x0 + 1;
  int get maxPartH => _partH < 0 ? height : _partH;
  int get maxPartW => _partW < 0 ? width : _partW;

  int get height => y1 - y0 + 1;
  Offset get center => Offset((x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2);
  double get meanLevel => n == 0 ? 255 : levelSum / n;
  double get coloredShare => n == 0 ? 0 : coloredN / n;

  void add(int x, int y, int level, int col) {
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
    n++;
    levelSum += level;
    coloredN += col;
  }

  void merge(_Comp o) {
    _partH = math.max(maxPartH, o.maxPartH);
    _partW = math.max(maxPartW, o.maxPartW);
    parts += o.parts;
    x0 = math.min(x0, o.x0);
    y0 = math.min(y0, o.y0);
    x1 = math.max(x1, o.x1);
    y1 = math.max(y1, o.y1);
    n += o.n;
    levelSum += o.levelSum;
    coloredN += o.coloredN;
  }
}

/// Ink statistics attached to a snapped word.
extension on PdfWord {
  static final _ink = Expando<_Comp>();
  _Comp? get ink => _ink[this];
  set ink(_Comp? c) => _ink[this] = c;
}
