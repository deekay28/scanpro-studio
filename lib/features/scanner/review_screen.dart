import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/import_service.dart';
import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../shared/widgets.dart';
import '../editor/crop_screen.dart';
import '../library/document_screen.dart';
import '../ocr/ocr_service.dart';
import '../ocr/text_analysis.dart';
import 'scan_flow.dart';

/// Batch review: reorder, crop, rotate, retake or delete captured pages,
/// choose a filter, then save as a new document (or append to one).
class ReviewScreen extends ConsumerStatefulWidget {
  final ScanSessionData session;
  const ReviewScreen({super.key, required this.session});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  late ScanSessionData _s = widget.session;
  late FilterPreset _preset = ref.read(settingsProvider).defaultPreset;
  bool _runOcr = false;
  int _thumbRev = 0;

  @override
  void initState() {
    super.initState();
    _runOcr = ref.read(settingsProvider).autoOcr;
  }

  DocumentRepository get _repo => ref.read(repositoryProvider);

  Future<void> _update(List<SessionItem> items) async {
    setState(() => _s = _s.copyWith(items: items));
    await _repo.saveSession(_s);
  }

  Future<void> _addMore() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Capture more with camera'),
            onTap: () async {
              Navigator.pop(ctx);
              final path = await ImportService.captureWithSystemCamera();
              if (path != null) await _appendPaths([path]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Add from gallery'),
            onTap: () async {
              Navigator.pop(ctx);
              final paths = await ImportService.pickImages();
              await _appendPaths(paths);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _appendPaths(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    await runBusy<void>(context, 'Adding pages…', (ctl) async {
      final items = [..._s.items];
      for (var i = 0; i < paths.length; i++) {
        ctl.update('Adding ${i + 1} of ${paths.length}…', (i + 1) / paths.length);
        final norm = await ImportService.normalize(paths[i]);
        items.add(await ScanFlow.makeItem(_repo, _s, norm.path, existing: items, downscaled: norm.downscaled));
      }
      await _update(items);
    });
  }

  Future<void> _retake(int index) async {
    final path = await ImportService.captureWithSystemCamera();
    if (path == null || !mounted) return;
    await runBusy<void>(context, 'Replacing page…', (ctl) async {
      final items = [..._s.items];
      final old = items[index];
      final others = [...items]..removeAt(index);
      items[index] = await ScanFlow.makeItem(_repo, _s, path, existing: others);
      await _repo.storage.deleteRel(old.path);
      await _update(items);
    });
  }

  Future<void> _crop(int index) async {
    final item = _s.items[index];
    final result = await Navigator.of(context).push<CropResult>(MaterialPageRoute(
      builder: (_) => CropScreen(imagePath: _repo.storage.abs(item.path), initialCorners: item.corners, rotation: item.rotation),
    ));
    if (result == null) return;
    final items = [..._s.items];
    items[index] = SessionItem(
      path: item.path,
      corners: result.corners,
      flags: item.flags.where((f) => f != QualityFlag.incomplete).toList(),
      hash: item.hash,
      rotation: result.rotation,
    );
    await _update(items);
    setState(() => _thumbRev++);
  }

  Future<void> _delete(int index) async {
    final items = [..._s.items];
    final removed = items.removeAt(index);
    await _update(items);
    if (!mounted) return;
    showSnack(context, 'Page deleted', action: SnackBarAction(label: 'Undo', onPressed: () => _update([...items]..insert(index, removed))));
  }

  Future<void> _discard() async {
    final ok = await confirm(context, 'Discard scan?', 'All ${_s.items.length} captured pages will be deleted.', ok: 'Discard', destructive: true);
    if (!ok) return;
    await _repo.discardSession(_s.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_s.items.isEmpty) return;
    final repo = _repo;
    final settings = ref.read(settingsProvider);
    // Duplicate document warning based on the first page.
    final firstHash = _s.items.first.hash;
    if (firstHash != null && _s.targetDocId == null) {
      final dups = await repo.findDuplicatesByHash(firstHash);
      if (dups.isNotEmpty && mounted) {
        final go = await confirm(context, 'Possible duplicate',
            'This looks like an existing document: "${dups.first.title}". Save anyway?', ok: 'Save anyway');
        if (!go) return;
      }
    }
    if (!mounted) return;
    final created = await runBusy<String>(context, 'Saving document…', (ctl) async {
      final target = _s.targetDocId == null ? null : await repo.getDocument(_s.targetDocId!);
      final doc = target ??
          await repo.createDocument(
            title: Naming.unique(Naming.defaultScanTitle(), await repo.allTitles()),
            kind: _s.mode == 'import' ? DocKind.images : DocKind.scan,
          );
      final pages = <DocPage>[];
      for (var i = 0; i < _s.items.length; i++) {
        if (ctl.cancelled) break;
        ctl.update('Processing page ${i + 1} of ${_s.items.length}…', (i + 1) / _s.items.length);
        final it = _s.items[i];
        final page = await repo.addPage(
          doc.id,
          repo.storage.abs(it.path),
          edit: PageEdit(corners: it.corners, rotation: it.rotation, preset: _preset),
        );
        pages.add(page);
      }
      if (_runOcr) {
        for (var i = 0; i < pages.length; i++) {
          if (ctl.cancelled) break;
          ctl.update('Recognising text ${i + 1} of ${pages.length}…', (i + 1) / pages.length);
          try {
            await ocrService.recognizePage(repo, pages[i], settings.ocrScript);
          } catch (_) {
            // OCR failures never block saving the scan.
          }
        }
      }
      await repo.completeSession(_s.id);
      return doc.id;
    }, cancellable: true);
    if (created == null || !mounted) return;
    // Name suggestions (OCR-based when text is available).
    if (_s.targetDocId == null) {
      final pages = await repo.getPages(created);
      final text = pages.map((e) => e.ocrText ?? '').join('\n');
      final suggestions = TextAnalysis.suggestNames(text);
      final doc = await repo.getDocument(created);
      if (!mounted) return;
      final name = await promptText(context, 'Name this document', initial: doc?.title ?? '', suggestions: suggestions, ok: 'Save');
      if (name != null && name.trim().isNotEmpty) await repo.rename(created, Naming.sanitize(name, maxLength: 120));
      final type = TextAnalysis.classify(text);
      if (type != null) await repo.setDocType(created, type);
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DocumentScreen(docId: created)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _s.items;
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Review ${items.length} page${items.length == 1 ? '' : 's'}'),
          actions: [
            IconButton(onPressed: _addMore, icon: const Icon(Icons.add_a_photo_outlined), tooltip: 'Add pages'),
            IconButton(onPressed: _discard, icon: const Icon(Icons.delete_outline), tooltip: 'Discard scan'),
          ],
        ),
        body: items.isEmpty
            ? EmptyState(
                icon: Icons.photo_outlined,
                title: 'No pages',
                message: 'Add pages with the camera or from the gallery.',
                action: FilledButton.icon(onPressed: _addMore, icon: const Icon(Icons.add), label: const Text('Add pages')),
              )
            : ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
                itemCount: items.length,
                onReorder: (a, b) {
                  final list = [...items];
                  if (b > a) b--;
                  final it = list.removeAt(a);
                  list.insert(b, it);
                  _update(list);
                },
                itemBuilder: (ctx, i) {
                  final it = items[i];
                  return Card(
                    key: ValueKey(it.path),
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        GestureDetector(
                          onTap: () => _crop(i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 96,
                              height: 128,
                              child: Stack(fit: StackFit.expand, children: [
                                StoredImage(it.path, cacheWidth: 240, key: ValueKey('${it.path}$_thumbRev')),
                                if (it.corners != null)
                                  CustomPaint(painter: _QuadThumbPainter(it.corners!)),
                              ]),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Page ${i + 1}', style: Theme.of(ctx).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              it.corners != null ? 'Edges detected · tap to adjust' : 'Full image · tap to crop',
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                            if (it.rotation != 0) Text('Rotated ${it.rotation}°', style: Theme.of(ctx).textTheme.bodySmall),
                            const SizedBox(height: 6),
                            FlagChips(it.flags, dense: true),
                            Wrap(children: [
                              IconButton(onPressed: () => _crop(i), icon: const Icon(Icons.crop), tooltip: 'Crop & rotate'),
                              IconButton(onPressed: () => _retake(i), icon: const Icon(Icons.replay), tooltip: 'Retake'),
                              IconButton(onPressed: () => _delete(i), icon: const Icon(Icons.delete_outline), tooltip: 'Delete'),
                            ]),
                          ]),
                        ),
                        ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
                      ]),
                    ),
                  );
                },
              ),
        bottomNavigationBar: items.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      height: 44,
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        for (final p in FilterPreset.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(p.label),
                              selected: _preset == p,
                              onSelected: (_) => setState(() => _preset = p),
                              tooltip: p.description,
                            ),
                          ),
                      ]),
                    ),
                    Row(children: [
                      Expanded(
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: _runOcr,
                          onChanged: (v) => setState(() => _runOcr = v ?? false),
                          title: const Text('Recognise text (OCR)'),
                          subtitle: const Text('Enables search & name suggestions'),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.check),
                        label: Text(_s.targetDocId == null ? 'Save' : 'Add pages'),
                      ),
                    ]),
                  ]),
                ),
              ),
      ),
    );
  }
}

class _QuadThumbPainter extends CustomPainter {
  final List<double> c;
  _QuadThumbPainter(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(c[0] * size.width, c[1] * size.height);
    for (var i = 1; i < 4; i++) {
      path.lineTo(c[i * 2] * size.width, c[i * 2 + 1] * size.height);
    }
    path.close();
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.lightBlueAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _QuadThumbPainter old) => old.c != c;
}
