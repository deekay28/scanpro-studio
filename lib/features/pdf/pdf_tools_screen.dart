import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../shared/widgets.dart';
import '../library/document_screen.dart';
import 'export_actions.dart';
import 'pdf_library.dart';
import 'pdf_service.dart';
import 'pdf_viewer_screen.dart';

/// Implementations of the PDF tools. Every operation writes a NEW file;
/// the source PDF is never modified in place.
class PdfTools {
  static void _show(BuildContext context, Uint8List bytes, String title, {String? parentId, String? password}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(bytes: bytes, title: title, parentId: parentId, password: password),
    ));
  }

  static Future<void> merge(BuildContext context, WidgetRef ref) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MergeScreen()));
  }

  static Future<LoadedPdf?> _pickOne(BuildContext context) async {
    try {
      final l = await PdfLibrary.pickAndOpen(context);
      return l.isEmpty ? null : l.first;
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e));
      return null;
    }
  }

  static Future<void> pickThen(BuildContext context, WidgetRef ref, String tool) async {
    final l = await _pickOne(context);
    if (l == null || !context.mounted) return;
    switch (tool) {
      case 'organize':
        await organize(context, ref, l);
      case 'compress':
        await compress(context, ref, l);
      case 'split':
        await split(context, ref, l);
      case 'protect':
        await protect(context, ref, l);
      case 'unlock':
        await unlock(context, ref, l);
      case 'images':
        await toImages(context, ref, l);
      case 'text':
        await showText(context, l);
      case 'view':
        _show(context, l.bytes, l.name, password: l.password);
    }
  }

  static Future<void> pickAndCompress(BuildContext context, WidgetRef ref) => pickThen(context, ref, 'compress');

  static Future<void> organize(BuildContext context, WidgetRef ref, LoadedPdf l, {String? parentId}) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrganizeScreen(pdf: l, parentId: parentId)));
  }

  static Future<void> compress(BuildContext context, WidgetRef ref, LoadedPdf l, {String? parentId}) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text('Compress "${l.name}" (${formatBytes(l.bytes.length)})', style: const TextStyle(fontWeight: FontWeight.w600))),
            ListTile(
              leading: const Icon(Icons.compress),
              title: const Text('Optimise (lossless)'),
              subtitle: const Text('Recompresses structure; keeps text, vectors and image quality'),
              onTap: () => Navigator.pop(ctx, 'lossless'),
            ),
            const Divider(),
            const ListTile(
              dense: true,
              title: Text('Strong compression (renders pages as images)'),
              subtitle: Text('Text stays searchable via an invisible text layer, but vector graphics become images.'),
            ),
            for (final pr in CompressionPreset.all)
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(pr.label),
                subtitle: Text('${pr.hint} · ${pr.rasterDpi.round()} dpi, JPEG ${pr.quality}%'),
                onTap: () => Navigator.pop(ctx, pr.id),
              ),
          ]),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final out = await runBusy(context, 'Compressing…', (ctl) async {
      if (choice == 'lossless') {
        return PdfService.rebuild([l.source], [for (var i = 0; i < l.info.pageCount; i++) PdfPageRef(0, i)],
            maxCompression: true, newPassword: l.password, title: l.info.title);
      }
      final preset = CompressionPreset.all.firstWhere((e) => e.id == choice);
      return PdfService.rasterCompress(l.source, preset,
          newPassword: l.password, onProgress: (d, t) => ctl.update('Compressing page $d of $t…', d / t), isCancelled: () => ctl.cancelled);
    }, cancellable: true);
    if (out == null || !context.mounted) return;
    final saved = l.bytes.length - out.length;
    showSnack(
      context,
      saved > 0
          ? '${formatBytes(l.bytes.length)} → ${formatBytes(out.length)} (${(saved * 100 / l.bytes.length).round()}% smaller)'
          : 'No reduction possible (${formatBytes(out.length)}). The original is already compact.',
    );
    _show(context, out, '${l.name} (compressed)', parentId: parentId, password: l.password);
  }

  static Future<void> split(BuildContext context, WidgetRef ref, LoadedPdf l, {String? parentId}) async {
    final n = l.info.pageCount;
    final controller = TextEditingController(text: n > 1 ? '1-${(n / 2).ceil()}, ${(n / 2).ceil() + 1}-$n' : '1');
    var mode = 'split';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Split / extract ($n pages)'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'split', label: Text('Split into files')),
                ButtonSegment(value: 'extract', label: Text('Extract to one')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setS(() => mode = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Page ranges', hintText: 'e.g. 1-3, 5, 8-'),
            ),
            const SizedBox(height: 6),
            Text(mode == 'split' ? 'Each range becomes a separate PDF.' : 'All listed pages go into one new PDF, in this order.',
                style: Theme.of(ctx).textTheme.bodySmall),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    List<List<int>> groups;
    try {
      groups = PdfService.parseRanges(controller.text, n);
    } catch (e) {
      showSnack(context, friendlyError(e));
      return;
    }
    if (mode == 'extract') {
      final pages = [for (final g in groups) ...g];
      final out = await runBusy(context, 'Extracting pages…',
          (_) async => PdfService.rebuild([l.source], [for (final i in pages) PdfPageRef(0, i)], newPassword: l.password));
      if (out != null && context.mounted) _show(context, out, '${l.name} (pages ${controller.text.replaceAll(' ', '')})', parentId: parentId, password: l.password);
      return;
    }
    final outputs = await runBusy(context, 'Splitting…', (ctl) async {
      final res = <(String, Uint8List)>[];
      for (var k = 0; k < groups.length; k++) {
        ctl.update('Creating file ${k + 1} of ${groups.length}…', (k + 1) / groups.length);
        final g = groups[k];
        final bytes = PdfService.rebuild([l.source], [for (final i in g) PdfPageRef(0, i)], newPassword: l.password);
        res.add(('${l.name} (${g.first + 1}-${g.last + 1})', bytes));
      }
      return res;
    });
    if (outputs == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MultiResultScreen(results: outputs, parentId: parentId, password: l.password)));
  }

  static Future<void> protect(BuildContext context, WidgetRef ref, LoadedPdf l, {String? parentId}) async {
    final pw = await promptText(context, 'Set PDF password', hint: 'At least 4 characters', obscure: true, ok: 'Next');
    if (pw == null || !context.mounted) return;
    if (pw.length < 4) {
      showSnack(context, 'Password is too short');
      return;
    }
    final again = await promptText(context, 'Confirm password', obscure: true, ok: 'Protect');
    if (again != pw || !context.mounted) {
      if (context.mounted && again != null) showSnack(context, 'Passwords do not match');
      return;
    }
    final out = await runBusy(context, 'Encrypting (AES-256)…',
        (_) async => PdfService.rebuild([l.source], [for (var i = 0; i < l.info.pageCount; i++) PdfPageRef(0, i)], newPassword: pw, title: l.info.title));
    if (out != null && context.mounted) _show(context, out, '${l.name} (protected)', parentId: parentId, password: pw);
  }

  static Future<void> unlock(BuildContext context, WidgetRef ref, LoadedPdf l, {String? parentId}) async {
    if (l.password == null) {
      showSnack(context, 'This PDF is not password protected');
      return;
    }
    final out = await runBusy(context, 'Removing password…',
        (_) async => PdfService.rebuild([l.source], [for (var i = 0; i < l.info.pageCount; i++) PdfPageRef(0, i)], title: l.info.title));
    if (out != null && context.mounted) _show(context, out, '${l.name} (unlocked)', parentId: parentId);
  }

  static Future<void> toImages(BuildContext context, WidgetRef ref, LoadedPdf l) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share pages as PNG images'), onTap: () => Navigator.pop(ctx, 'share')),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Convert to editable scan document'),
            subtitle: const Text('Filters, OCR, annotations and rebuilt PDFs'),
            onTap: () => Navigator.pop(ctx, 'doc'),
          ),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    final repo = ref.read(repositoryProvider);
    final plain = l.password == null
        ? l.bytes
        : PdfService.rebuild([l.source], [for (var i = 0; i < l.info.pageCount; i++) PdfPageRef(0, i)]);
    final result = await runBusy(context, 'Rendering pages…', (ctl) async {
      final dir = Directory(p.join(repo.storage.cache.path, 'pdfimg_${newId()}'));
      await dir.create(recursive: true);
      final paths = <String>[];
      await for (final (i, png) in PdfService.renderPages(plain, dpi: choice == 'doc' ? 200 : 150)) {
        if (ctl.cancelled) break;
        ctl.update('Rendering page ${i + 1} of ${l.info.pageCount}…', (i + 1) / l.info.pageCount);
        final f = File(p.join(dir.path, '${Naming.sanitize(l.name)}_${(i + 1).toString().padLeft(3, '0')}.png'));
        await f.writeAsBytes(png, flush: true);
        paths.add(f.path);
      }
      if (choice == 'share') return (paths, null as String?);
      final doc = await repo.createDocument(title: Naming.unique(l.name, await repo.allTitles()), kind: DocKind.images);
      for (var k = 0; k < paths.length; k++) {
        ctl.update('Adding page ${k + 1} of ${paths.length}…', (k + 1) / paths.length);
        await repo.addPage(doc.id, paths[k], edit: const PageEdit(), documentExpected: false);
      }
      return (paths, doc.id);
    }, cancellable: true);
    if (result == null || !context.mounted) return;
    if (result.$2 != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: result.$2!)));
    } else {
      await ExportActions.shareFiles(result.$1);
    }
  }

  static Future<void> showText(BuildContext context, LoadedPdf l) async {
    final texts = await runBusy(context, 'Extracting text…', (_) async => PdfService.extractText(l.source));
    if (texts == null || !context.mounted) return;
    final all = [for (var i = 0; i < texts.length; i++) '--- Page ${i + 1} ---\n${texts[i].trim()}'].join('\n\n');
    final empty = texts.every((t) => t.trim().isEmpty);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: const Text('PDF text'), actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: all));
              showSnack(ctx, 'Copied');
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Share TXT',
            onPressed: () => ExportActions.shareBytes(Uint8List.fromList(utf8.encode(all)), Naming.withExtension(l.name, 'txt'), mime: 'text/plain'),
            icon: const Icon(Icons.share_outlined),
          ),
        ]),
        body: empty
            ? const EmptyState(
                icon: Icons.image_not_supported_outlined,
                title: 'No text layer',
                message: 'This PDF contains only images. Use "To images → Convert to editable scan document" and then OCR.',
              )
            : SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(all)),
      ),
    ));
  }
}

/// Merge: pick several PDFs, order them, combine (vector copy).
class MergeScreen extends ConsumerStatefulWidget {
  const MergeScreen({super.key});

  @override
  ConsumerState<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends ConsumerState<MergeScreen> {
  final List<LoadedPdf> _files = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _add());
  }

  Future<void> _add() async {
    try {
      final l = await PdfLibrary.pickAndOpen(context, multiple: true);
      setState(() => _files.addAll(l));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _merge() async {
    if (_files.length < 2) {
      showSnack(context, 'Add at least two PDFs');
      return;
    }
    final out = await runBusy(context, 'Merging…', (_) async {
      final refs = <PdfPageRef>[];
      for (var s = 0; s < _files.length; s++) {
        for (var i = 0; i < _files[s].info.pageCount; i++) {
          refs.add(PdfPageRef(s, i));
        }
      }
      return PdfService.rebuild(_files.map((f) => f.source).toList(), refs, title: 'Merged document');
    });
    if (out != null && mounted) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(bytes: out, title: 'Merged ${formatDate(DateTime.now())}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _files.fold<int>(0, (a, f) => a + f.info.pageCount);
    return Scaffold(
      appBar: AppBar(title: Text('Merge PDFs (${_files.length})'), actions: [
        IconButton(onPressed: _add, icon: const Icon(Icons.add), tooltip: 'Add PDFs'),
      ]),
      body: _files.isEmpty
          ? EmptyState(icon: Icons.merge_type, title: 'Select PDFs to merge', action: FilledButton(onPressed: _add, child: const Text('Choose files')))
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _files.length,
              onReorder: (a, b) => setState(() {
                if (b > a) b--;
                _files.insert(b, _files.removeAt(a));
              }),
              itemBuilder: (ctx, i) {
                final f = _files[i];
                return Card(
                  key: ObjectKey(f),
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(f.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${f.info.pageCount} pages · ${formatBytes(f.bytes.length)}${f.password != null ? ' · protected' : ''}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(onPressed: () => setState(() => _files.removeAt(i)), icon: const Icon(Icons.close), tooltip: 'Remove'),
                      ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                    ]),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(onPressed: _files.length < 2 ? null : _merge, icon: const Icon(Icons.merge_type), label: Text('Merge $total pages')),
        ),
      ),
    );
  }
}

/// Visual page organiser for an existing PDF: reorder, rotate, delete,
/// duplicate and insert blank pages, then save as a new PDF.
class OrganizeScreen extends ConsumerStatefulWidget {
  final LoadedPdf pdf;
  final String? parentId;
  const OrganizeScreen({super.key, required this.pdf, this.parentId});

  @override
  ConsumerState<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends ConsumerState<OrganizeScreen> {
  late List<_OrgPage> _pages = [for (var i = 0; i < widget.pdf.info.pageCount; i++) _OrgPage(PdfPageRef(0, i), newId())];
  final Map<int, Uint8List> _thumbs = {};
  Uint8List? _plain;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _renderThumbs();
  }

  Future<void> _renderThumbs() async {
    try {
      final l = widget.pdf;
      _plain = l.password == null ? l.bytes : PdfService.rebuild([l.source], [for (var i = 0; i < l.info.pageCount; i++) PdfPageRef(0, i)]);
      var i = 0;
      await for (final png in PdfService.thumbnails(_plain!, dpi: 30)) {
        if (!mounted) return;
        setState(() => _thumbs[i] = png);
        i++;
      }
    } catch (_) {}
  }

  void _rotateSelected(int d) => setState(() {
        _pages = [for (final pg in _pages) _selected.contains(pg.key) ? _OrgPage(pg.ref.rotated(d), pg.key) : pg];
      });

  void _deleteSelected() => setState(() {
        _pages = _pages.where((pg) => !_selected.contains(pg.key)).toList();
        _selected.clear();
      });

  void _duplicateSelected() => setState(() {
        final out = <_OrgPage>[];
        for (final pg in _pages) {
          out.add(pg);
          if (_selected.contains(pg.key)) out.add(_OrgPage(pg.ref, newId()));
        }
        _pages = out;
      });

  void _insertBlank() => setState(() {
        var idx = _pages.length;
        if (_selected.isNotEmpty) idx = _pages.lastIndexWhere((pg) => _selected.contains(pg.key)) + 1;
        _pages.insert(idx, _OrgPage(const PdfPageRef(0, -1), newId()));
      });

  Future<void> _save() async {
    if (_pages.isEmpty) {
      showSnack(context, 'At least one page is required');
      return;
    }
    final l = widget.pdf;
    final out = await runBusy(context, 'Saving new PDF…', (_) async {
      final size = l.info.pageSizes.isNotEmpty ? l.info.pageSizes.first : const Size(595.28, 841.89);
      return PdfService.rebuild([l.source], _pages.map((e) => e.ref).toList(), newPassword: l.password, title: l.info.title, blankSize: size);
    });
    if (out != null && mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(bytes: out, title: '${l.name} (edited)', parentId: widget.parentId, password: l.password),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(sel ? '${_selected.length} selected' : 'Organise pages'),
        actions: [
          IconButton(
            tooltip: sel ? 'Clear selection' : 'Select all',
            onPressed: () => setState(() => sel ? _selected.clear() : _selected.addAll(_pages.map((e) => e.key))),
            icon: Icon(sel ? Icons.deselect : Icons.select_all),
          ),
          TextButton(onPressed: _save, child: const Text('Save as new')),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _pages.length,
        onReorder: (a, b) => setState(() {
          if (b > a) b--;
          _pages.insert(b, _pages.removeAt(a));
        }),
        itemBuilder: (ctx, i) {
          final pg = _pages[i];
          final thumb = pg.ref.blank ? null : _thumbs[pg.ref.index];
          return Card(
            key: ValueKey(pg.key),
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: _selected.contains(pg.key) ? Theme.of(ctx).colorScheme.primaryContainer : null,
            child: ListTile(
              onTap: () => setState(() => _selected.contains(pg.key) ? _selected.remove(pg.key) : _selected.add(pg.key)),
              leading: SizedBox(
                width: 48,
                height: 64,
                child: RotatedBox(
                  quarterTurns: pg.ref.rotation ~/ 90,
                  child: pg.ref.blank
                      ? Container(color: Colors.white, child: const Icon(Icons.crop_portrait, color: Colors.grey))
                      : thumb == null
                          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                          : Image.memory(thumb, fit: BoxFit.contain),
                ),
              ),
              title: Text(pg.ref.blank ? 'Blank page' : 'Page ${pg.ref.index + 1}'),
              subtitle: Text('Position ${i + 1}${pg.ref.rotation != 0 ? ' · rotated ${pg.ref.rotation}°' : ''}'),
              trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(onPressed: sel ? () => _rotateSelected(270) : null, icon: const Icon(Icons.rotate_left), tooltip: 'Rotate left'),
          IconButton(onPressed: sel ? () => _rotateSelected(90) : null, icon: const Icon(Icons.rotate_right), tooltip: 'Rotate right'),
          IconButton(onPressed: sel ? _duplicateSelected : null, icon: const Icon(Icons.copy), tooltip: 'Duplicate'),
          IconButton(onPressed: _insertBlank, icon: const Icon(Icons.note_add_outlined), tooltip: 'Insert blank page'),
          IconButton(onPressed: sel ? _deleteSelected : null, icon: const Icon(Icons.delete_outline), tooltip: 'Delete'),
        ]),
      ),
    );
  }
}

class _OrgPage {
  final PdfPageRef ref;
  final String key;
  const _OrgPage(this.ref, this.key);
}

/// Lists several generated PDFs (e.g. split output).
class MultiResultScreen extends ConsumerWidget {
  final List<(String, Uint8List)> results;
  final String? parentId;
  final String? password;
  const MultiResultScreen({super.key, required this.results, this.parentId, this.password});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('${results.length} files created'), actions: [
        TextButton(
          onPressed: () async {
            final repo = ref.read(repositoryProvider);
            await runBusy<void>(context, 'Saving to library…', (_) async {
              for (final r in results) {
                await PdfLibrary.saveToLibrary(repo, r.$2, r.$1, parentId: parentId, password: password);
              }
            });
            if (context.mounted) showSnack(context, 'All files saved to Documents');
          },
          child: const Text('Save all in app'),
        ),
      ]),
      body: ListView(children: [
        for (final r in results)
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(r.$1),
            subtitle: Text(formatBytes(r.$2.length)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PdfViewerScreen(bytes: r.$2, title: r.$1, parentId: parentId, password: password),
            )),
            trailing: IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => ExportActions.shareBytes(r.$2, Naming.withExtension(r.$1, 'pdf'), mime: 'application/pdf'),
            ),
          ),
      ]),
    );
  }
}
