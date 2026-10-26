import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/storage.dart' show friendlyError;
import '../../../shared/widgets.dart';
import '../../convert/doc_to_pdf.dart';
import '../../convert/model/page_content.dart';
import '../../convert/ooxml/docx.dart';
import '../../pdf/export_actions.dart';
import '../../pdf/pdf_library.dart';
import '../../pdf_editor/engine/engine_worker.dart';
import '../services/pdf_comparison_service.dart';
import '../suite.dart';
import 'page_cache.dart';

/// Compares two PDFs: text insertions, deletions and changed values (with
/// their positions), page count and size changes, and a visual comparison
/// for pages that are images on both sides (scans). Results are shown side
/// by side with synchronised scrolling and can be exported as a report.
class CompareScreen extends StatefulWidget {
  final LoadedPdf? first;
  const CompareScreen({super.key, this.first});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  LoadedPdf? _a, _b;
  HostSession? _sa, _sb;
  PageRenderCache? _ca, _cb;
  ComparisonResult? _result;
  final _left = ScrollController(), _right = ScrollController();
  var _syncing = false;
  var _sideBySide = true;

  @override
  void initState() {
    super.initState();
    _a = widget.first;
    _left.addListener(() => _sync(_left, _right));
    _right.addListener(() => _sync(_right, _left));
  }

  @override
  void dispose() {
    _close();
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  void _close() {
    _ca?.dispose();
    _cb?.dispose();
    _sa?.close();
    _sb?.close();
    _sa = _sb = null;
    _ca = _cb = null;
  }

  void _sync(ScrollController from, ScrollController to) {
    if (_syncing || !from.hasClients || !to.hasClients) return;
    _syncing = true;
    final f = from.position, t = to.position;
    final ratio = f.maxScrollExtent <= 0 ? 0.0 : f.pixels / f.maxScrollExtent;
    to.jumpTo((ratio * t.maxScrollExtent).clamp(0.0, t.maxScrollExtent));
    _syncing = false;
  }

  Future<void> _pick(bool first) async {
    try {
      final l = await PdfLibrary.pickAndOpen(context);
      if (l.isEmpty) return;
      setState(() {
        if (first) {
          _a = l.first;
        } else {
          _b = l.first;
        }
        _result = null;
      });
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _compare() async {
    final a = _a!, b = _b!;
    _close();
    final r = await runBusy(context, 'Comparing…', cancellable: true, (ctl) async {
      final suite = await DocSuite.get();
      final sa = await suite.host.open(a.bytes, password: a.password);
      final sb = await suite.host.open(b.bytes, password: b.password);
      _sa = sa;
      _sb = sb;
      final total = sa.pageCount + sb.pageCount;
      final pa = <PageContent>[], pb = <PageContent>[];
      for (var i = 0; i < sa.pageCount; i++) {
        if (ctl.cancelled) throw OperationCancelled();
        ctl.update('Reading original, page ${i + 1}…', i / total);
        pa.add(await sa.call<PageContent>('content', [i, false]));
      }
      for (var i = 0; i < sb.pageCount; i++) {
        if (ctl.cancelled) throw OperationCancelled();
        ctl.update('Reading revised, page ${i + 1}…', (sa.pageCount + i) / total);
        pb.add(await sb.call<PageContent>('content', [i, false]));
      }
      ctl.update('Finding differences…', null);
      final text = await compute(_compareText, (pa, pb));
      // Pages without text on both sides (scans) are compared visually.
      final visual = <VisualChange>[];
      for (var i = 0; i < math.min(pa.length, pb.length); i++) {
        if (!(pa[i].scanned && pb[i].scanned)) continue;
        if (ctl.cancelled) throw OperationCancelled();
        ctl.update('Comparing scanned page ${i + 1}…', null);
        final size = pa[i].size;
        const scale = 1.0;
        final ra = await sa.call<RenderedPage>('renderOriginal', [i, scale]);
        final rb = await sb.call<RenderedPage>('renderOriginal', [i, scale * size.width / pb[i].size.width]);
        if (ra.width != rb.width || ra.height != rb.height) continue;
        final v = await compute(_compareRender, (i, ra.rgba, rb.rgba, ra.width, ra.height, size.width / ra.width));
        if (v != null) visual.add(v);
      }
      final result = ComparisonResult(text.changes, text.structure, visual, text.oldWords, text.newWords, approximate: text.approximate);
      _ca = await PageRenderCache.open(sa);
      _cb = await PageRenderCache.open(sb);
      return result;
    });
    if (!mounted) return;
    setState(() => _result = r);
  }

  Map<int, List<Rect>> _rects(bool old, {Set<ChangeKind>? kinds}) {
    final out = <int, List<Rect>>{};
    for (final c in _result!.changes) {
      if (kinds != null && !kinds.contains(c.kind)) continue;
      final page = old ? c.oldPage : c.newPage;
      if (page == null) continue;
      out.putIfAbsent(page, () => []).addAll(old ? c.oldRects : c.newRects);
    }
    for (final v in _result!.visual) {
      out.putIfAbsent(v.page, () => []).addAll(v.regions);
    }
    return out;
  }

  Future<void> _export(String format) async {
    final r = _result!;
    final bytes = await runBusy(context, 'Writing report…', (ctl) async {
      final doc = comparisonReport(r, _a!.name, _b!.name);
      if (format == 'docx') return writeDocx(doc);
      final suite = await DocSuite.get();
      return DocPdfRenderer(suite.unicodeFont).render(doc);
    });
    if (bytes == null || !mounted) return;
    final name = 'Comparison - ${_a!.name} vs ${_b!.name}.$format';
    await ExportActions.shareBytes(bytes, name,
        mime: format == 'pdf' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  }

  void _jumpTo(TextChange c) {
    final cache = _cb ?? _ca;
    if (cache == null) return;
    final page = c.newPage ?? c.oldPage ?? 0;
    final useRight = c.newPage != null;
    final ctl = useRight ? _right : _left;
    final cc = useRight ? _cb! : _ca!;
    if (!ctl.hasClients) return;
    final width = ctl.position.viewportDimension > 0 ? (MediaQuery.sizeOf(context).width / (_sideBySide ? 2 : 1)) - 12 : 300.0;
    var y = 0.0;
    for (var i = 0; i < page && i < cc.pageCount; i++) {
      y += width * cc.sizes[i].height / cc.sizes[i].width + 8;
    }
    final rects = useRight ? c.newRects : c.oldRects;
    if (rects.isNotEmpty) y += rects.first.top * width / cc.sizes[page].width - 60;
    ctl.animateTo(y.clamp(0.0, ctl.position.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compare PDFs'),
        actions: [
          if (r != null) ...[
            IconButton(
              tooltip: _sideBySide ? 'Show revised only' : 'Side by side',
              icon: Icon(_sideBySide ? Icons.view_agenda_outlined : Icons.vertical_split_outlined),
              onPressed: () => setState(() => _sideBySide = !_sideBySide),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export report',
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pdf', child: Text('Report as PDF')),
                PopupMenuItem(value: 'docx', child: Text('Report as Word')),
              ],
            ),
          ],
        ],
      ),
      body: r == null ? _setup() : _results(r),
    );
  }

  Widget _setup() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Choose the original and the revised version. Text is compared word by word; scanned pages are compared visually.'),
        const SizedBox(height: 16),
        _fileCard('Original', _a, () => _pick(true)),
        _fileCard('Revised', _b, () => _pick(false)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _a != null && _b != null ? _compare : null, icon: const Icon(Icons.compare), label: const Text('Compare')),
        const SizedBox(height: 16),
        Text(
          'Only differences in the text and page structure are reported as changes, so re-saving, compression or different fonts do not create false changes. '
          'For scanned pages a visual difference may also come from scanning noise.',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ]);

  Widget _fileCard(String label, LoadedPdf? f, VoidCallback pick) => Card(
        child: ListTile(
          leading: const Icon(Icons.picture_as_pdf_outlined),
          title: Text(label),
          subtitle: Text(f == null ? 'Not selected' : '${f.name} · ${f.info.pageCount} page(s)'),
          trailing: TextButton(onPressed: pick, child: Text(f == null ? 'Choose' : 'Change')),
        ),
      );

  Widget _results(ComparisonResult r) {
    final cs = Theme.of(context).colorScheme;
    final ins = r.changes.where((c) => c.kind == ChangeKind.inserted).length;
    final del = r.changes.where((c) => c.kind == ChangeKind.deleted).length;
    final chg = r.changes.where((c) => c.kind == ChangeKind.changed).length;
    final oldRects = _rects(true), newRects = _rects(false);
    Widget column(PageRenderCache cache, ScrollController ctl, Map<int, List<Rect>> rects, Color color, String label) => Expanded(
          child: Column(children: [
            Padding(padding: const EdgeInsets.all(4), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, c) => ListView.builder(
                  controller: ctl,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: cache.pageCount,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Stack(children: [
                      RenderedPageView(cache: cache, page: i, width: c.maxWidth - 8, highlights: rects[i] ?? const [], highlightColor: color),
                      Positioned(right: 4, top: 4, child: Text('${i + 1}', style: const TextStyle(fontSize: 10, color: Colors.black54))),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        );

    return Column(children: [
      Container(
        width: double.infinity,
        color: cs.surfaceContainerHighest,
        padding: const EdgeInsets.all(10),
        child: Text(
          r.identical
              ? 'No differences found in the text or page structure.'
              : [
                  if (chg > 0) '$chg changed',
                  if (ins > 0) '$ins inserted',
                  if (del > 0) '$del deleted',
                  ...r.structure,
                  if (r.visual.isNotEmpty) '${r.visual.length} scanned page(s) look different',
                  if (r.approximate) 'compared page by page (very different documents)',
                ].join(' · '),
        ),
      ),
      if (r.changes.isNotEmpty)
        SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(6),
            itemCount: r.changes.length,
            itemBuilder: (ctx, i) {
              final c = r.changes[i];
              final color = switch (c.kind) { ChangeKind.inserted => Colors.green, ChangeKind.deleted => Colors.red, ChangeKind.changed => Colors.orange };
              return SizedBox(
                width: 220,
                child: Card(
                  child: InkWell(
                    onTap: () => _jumpTo(c),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          '${c.numeric ? 'Value changed' : switch (c.kind) { ChangeKind.inserted => 'Inserted', ChangeKind.deleted => 'Deleted', ChangeKind.changed => 'Changed' }} · p. ${(c.newPage ?? c.oldPage ?? 0) + 1}',
                          style: TextStyle(color: color.shade800, fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                        if (c.oldText.isNotEmpty) Text(c.oldText, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(decoration: TextDecoration.lineThrough, fontSize: 12)),
                        if (c.newText.isNotEmpty) Text(c.newText, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      Expanded(
        child: Row(children: [
          if (_sideBySide) column(_ca!, _left, oldRects, const Color(0x55F44336), 'Original'),
          column(_cb!, _right, newRects, const Color(0x5543A047), 'Revised'),
        ]),
      ),
    ]);
  }
}

ComparisonResult _compareText((List<PageContent>, List<PageContent>) a) => compareText(a.$1, a.$2);

VisualChange? _compareRender((int, Uint8List, Uint8List, int, int, double) a) => compareRender(a.$1, a.$2, a.$3, a.$4, a.$5, pointsPerPixel: a.$6);
