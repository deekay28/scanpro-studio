import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import '../editor/crop_screen.dart';
import '../library/document_screen.dart';

/// Review book spreads: adjust page area and spine, choose reading order,
/// shadow removal and approximate flattening, then save as one document.
class BookReviewScreen extends ConsumerStatefulWidget {
  final ScanSessionData session;
  const BookReviewScreen({super.key, required this.session});

  @override
  ConsumerState<BookReviewScreen> createState() => _BookReviewScreenState();
}

class _BookReviewScreenState extends ConsumerState<BookReviewScreen> {
  late ScanSessionData _s = widget.session;
  bool _rtl = false;
  bool _flatten = true;
  FilterPreset _preset = FilterPreset.documentColor;
  final Set<int> _single = {}; // spreads kept as one page
  double _overlap = 0.012;

  DocumentRepository get _repo => ref.read(repositoryProvider);

  Future<void> _update(List<SessionItem> items) async {
    setState(() => _s = _s.copyWith(items: items));
    await _repo.saveSession(_s);
  }

  Future<void> _adjustCorners(int i) async {
    final it = _s.items[i];
    final r = await Navigator.of(context).push<CropResult>(MaterialPageRoute(
      builder: (_) => CropScreen(imagePath: _repo.storage.abs(it.path), initialCorners: it.corners),
    ));
    if (r == null) return;
    final items = [..._s.items];
    items[i] = SessionItem(path: it.path, corners: r.corners, flags: it.flags, hash: it.hash, spine: it.spine, rotation: r.rotation);
    await _update(items);
  }

  int get _pageCount => _s.items.length * 2 - _single.length;

  Future<void> _save() async {
    final repo = _repo;
    final id = await runBusy(context, 'Creating book…', (ctl) async {
      final doc = await repo.createDocument(title: Naming.unique('Book ${Naming.defaultScanTitle().substring(5)}', await repo.allTitles()), kind: DocKind.book);
      var n = 0;
      for (var i = 0; i < _s.items.length; i++) {
        if (ctl.cancelled) break;
        final it = _s.items[i];
        final corners = it.corners ?? <double>[0, 0, 1, 0, 1, 1, 0, 1];
        final edit = PageEdit(preset: _preset, flatten: _flatten, rotation: it.rotation);
        if (_single.contains(i)) {
          ctl.update('Processing page ${++n} of $_pageCount…', n / _pageCount);
          await repo.addPage(doc.id, repo.storage.abs(it.path), edit: edit.copyWith(corners: corners), documentExpected: false);
          continue;
        }
        final (left, right) = splitSpread(corners, it.spine ?? 0.5, overlap: _overlap);
        final first = _rtl ? right : left, second = _rtl ? left : right;
        ctl.update('Processing page ${++n} of $_pageCount…', n / _pageCount);
        final p1 = await repo.addPage(doc.id, repo.storage.abs(it.path), edit: edit.copyWith(corners: first), documentExpected: false);
        ctl.update('Processing page ${++n} of $_pageCount…', n / _pageCount);
        await repo.addPage(doc.id, repo.storage.abs(it.path), edit: edit.copyWith(corners: second), documentExpected: false, sharedOriginalRel: p1.originalPath);
      }
      await repo.completeSession(_s.id);
      return doc.id;
    }, cancellable: true);
    if (id != null && mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DocumentScreen(docId: id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _s.items;
    return Scaffold(
      appBar: AppBar(
        title: Text('${items.length} spread(s) → $_pageCount pages'),
        actions: [
          IconButton(
            tooltip: 'Discard',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, 'Discard book scan?', 'All captured spreads will be deleted.', ok: 'Discard', destructive: true)) {
                await _repo.discardSession(_s.id);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 120), children: [
        SwitchListTile(
          title: const Text('Right-to-left book'),
          subtitle: const Text('Right page comes first (e.g. Urdu, Arabic)'),
          value: _rtl,
          onChanged: (v) => setState(() => _rtl = v),
        ),
        SwitchListTile(
          title: const Text('Flatten curved pages (approximate)'),
          subtitle: const Text('Uses the page edges against the background; originals kept'),
          value: _flatten,
          onChanged: (v) => setState(() => _flatten = v),
        ),
        LabeledSlider(
          label: 'Spine overlap',
          value: _overlap,
          min: 0,
          max: 0.05,
          format: (v) => '${(v * 100).toStringAsFixed(1)}%',
          onChanged: (v) => setState(() => _overlap = v),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text('Overlap keeps text near the binding on both pages.', style: Theme.of(context).textTheme.bodySmall),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final p in [FilterPreset.documentColor, FilterPreset.grayscale, FilterPreset.highContrastText, FilterPreset.blackWhite, FilterPreset.original])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(p.label), selected: _preset == p, onSelected: (_) => setState(() => _preset = p)),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++) _spreadCard(i, items[i]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(onPressed: items.isEmpty ? null : _save, icon: const Icon(Icons.check), label: Text('Create book ($_pageCount pages)')),
        ),
      ),
    );
  }

  Widget _spreadCard(int i, SessionItem it) {
    final single = _single.contains(i);
    final firstNo = List.generate(i, (k) => _single.contains(k) ? 1 : 2).fold<int>(0, (a, b) => a + b) + 1;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(single ? 'Spread ${i + 1} → page $firstNo' : 'Spread ${i + 1} → pages $firstNo–${firstNo + 1}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(fit: StackFit.expand, children: [
              StoredImage(it.path, fit: BoxFit.fill, cacheWidth: 800),
              CustomPaint(painter: _SpreadPainter(it.corners ?? const <double>[0, 0, 1, 0, 1, 1, 0, 1], single ? null : (it.spine ?? 0.5), _rtl)),
            ]),
          ),
          if (!single)
            LabeledSlider(
              label: 'Spine',
              value: it.spine ?? 0.5,
              min: 0.25,
              max: 0.75,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) {
                final items = [..._s.items];
                items[i] = it.copyWith(spine: v);
                setState(() => _s = _s.copyWith(items: items));
              },
              onChangeEnd: (_) => _repo.saveSession(_s),
            ),
          Row(children: [
            TextButton.icon(onPressed: () => _adjustCorners(i), icon: const Icon(Icons.crop), label: const Text('Page area')),
            const Spacer(),
            FilterChip(
              label: const Text('Single page'),
              selected: single,
              onSelected: (v) => setState(() => v ? _single.add(i) : _single.remove(i)),
            ),
            IconButton(
              tooltip: 'Remove spread',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _update([..._s.items]..removeAt(i)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _SpreadPainter extends CustomPainter {
  final List<double> c;
  final double? spine;
  final bool rtl;
  _SpreadPainter(this.c, this.spine, this.rtl);

  @override
  void paint(Canvas canvas, Size size) {
    Offset pt(double x, double y) => Offset(x * size.width, y * size.height);
    final quad = [pt(c[0], c[1]), pt(c[2], c[3]), pt(c[4], c[5]), pt(c[6], c[7])];
    final paint = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(Path()..addPolygon(quad, true), paint);
    final s = spine;
    if (s == null) return;
    final top = Offset.lerp(quad[0], quad[1], s)!, bottom = Offset.lerp(quad[3], quad[2], s)!;
    canvas.drawLine(top, bottom, Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 3);
    void label(String t, Offset o) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18, shadows: [Shadow(blurRadius: 4)])),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o - Offset(tp.width / 2, tp.height / 2));
    }

    final lc = Offset.lerp(Offset.lerp(quad[0], quad[3], 0.5), Offset.lerp(top, bottom, 0.5), 0.5)!;
    final rc = Offset.lerp(Offset.lerp(quad[1], quad[2], 0.5), Offset.lerp(top, bottom, 0.5), 0.5)!;
    label(rtl ? '2' : '1', lc);
    label(rtl ? '1' : '2', rc);
  }

  @override
  bool shouldRepaint(covariant _SpreadPainter old) => old.c != c || old.spine != spine || old.rtl != rtl;
}
