import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../core/units.dart';
import '../../core/storage.dart';
import '../../imaging/image_ops.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import '../backup/backup_service.dart';
import '../ocr/ocr_screen.dart';
import '../pdf/export_actions.dart';
import '../pdf/pdf_export_screen.dart';
import '../pdf/pdf_library.dart';
import '../pdf/pdf_tools_screen.dart';
import '../pdf/pdf_viewer_screen.dart';
import '../qr/qr_screen.dart';
import '../scanner/scan_flow.dart';
import '../security/vault.dart';
import 'page_viewer_screen.dart';

/// Document detail: page grid, reordering, page actions and exports.
class DocumentScreen extends ConsumerStatefulWidget {
  final String docId;
  final int? initialPage;
  const DocumentScreen({super.key, required this.docId, this.initialPage});

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  ScanDocument? _doc;
  List<DocPage> _pages = const [];
  bool _loading = true;
  bool _reorder = false;
  int _rev = -1;

  @override
  void initState() {
    super.initState();
    ref.read(repositoryProvider).markOpened(widget.docId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _load();
      final ip = widget.initialPage;
      if (ip != null && mounted && _doc != null && !_doc!.isPdf && ip < _pages.length) _openPage(ip);
    });
  }

  DocumentRepository get _repo => ref.read(repositoryProvider);

  Future<void> _load() async {
    final d = await _repo.getDocument(widget.docId);
    final pages = d == null ? <DocPage>[] : await _repo.getPages(widget.docId);
    if (!mounted) return;
    setState(() {
      _doc = d;
      _pages = pages;
      _loading = false;
      _rev = _repo.revision;
    });
  }

  void _openPage(int i) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PageViewerScreen(docId: widget.docId, initialIndex: i)));
  }

  Future<void> _rename() async {
    final d = _doc!;
    final text = _pages.map((p) => p.ocrText ?? '').join('\n');
    final name = await promptText(context, 'Rename document', initial: d.title, suggestions: text.trim().isEmpty ? const [] : _suggest(text));
    if (name != null && name.isNotEmpty) await _repo.rename(d.id, Naming.sanitize(name, maxLength: 120));
  }

  List<String> _suggest(String text) {
    // Imported lazily to keep this screen light.
    return OcrScreen.nameSuggestions(text);
  }

  Future<void> _tags() async {
    final d = _doc!;
    final all = await _repo.allTags();
    if (!mounted) return;
    final current = {...d.tags};
    final controller = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Tags'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in {...all, ...current, 'Invoice', 'Receipt', 'Certificate', 'ID', 'Work', 'Personal'})
                  FilterChip(
                    label: Text(t),
                    selected: current.contains(t),
                    onSelected: (v) => setS(() => v ? current.add(t) : current.remove(t)),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(hintText: 'New tag'),
                onSubmitted: (v) => setS(() {
                  if (v.trim().isNotEmpty) current.add(v.trim());
                  controller.clear();
                }),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, current), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result != null) await _repo.setTags(d.id, result.toList());
  }

  Future<void> _moveToFolder() async {
    final folders = await _repo.listFolders();
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(leading: const Icon(Icons.home_outlined), title: const Text('No folder'), onTap: () => Navigator.pop(ctx, '')),
          for (final f in folders)
            ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f.name), onTap: () => Navigator.pop(ctx, f.id)),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder…'),
            onTap: () async {
              final name = await promptText(ctx, 'New folder');
              if (name == null || name.isEmpty) return;
              final f = await _repo.createFolder(name);
              if (ctx.mounted) Navigator.pop(ctx, f.id);
            },
          ),
        ]),
      ),
    );
    if (choice == null) return;
    await _repo.moveToFolder(widget.docId, choice.isEmpty ? null : choice);
  }

  Future<void> _delete() async {
    final ok = await confirm(context, 'Move to Recently deleted?',
        'You can restore it within ${ref.read(settingsProvider).trashRetentionDays} days.', ok: 'Delete', destructive: true);
    if (!ok) return;
    await _repo.softDelete(widget.docId);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addBlankPage() async {
    final repo = _repo;
    await runBusy<void>(context, 'Adding blank page…', (_) async {
      final path = repo.storage.tempPath('blank.jpg');
      final w = mmToPx(210, 150).round(), h = mmToPx(297, 150).round();
      await Isolate.run(() => writeAtomic(path, encodeJpeg(Rgb.blank(w, h), 90)));
      await repo.addPage(widget.docId, path, edit: const PageEdit(), documentExpected: false);
    });
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Scan pages'),
            onTap: () {
              Navigator.pop(ctx);
              ScanFlow.smartScan(context, ref, targetDocId: widget.docId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Pro camera'),
            onTap: () {
              Navigator.pop(ctx);
              ScanFlow.proCamera(context, ref, targetDocId: widget.docId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Import images'),
            onTap: () {
              Navigator.pop(ctx);
              ScanFlow.importImages(context, ref, targetDocId: widget.docId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Blank page'),
            onTap: () {
              Navigator.pop(ctx);
              _addBlankPage();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _exportImages() async {
    final paths = [for (final p in _pages) _repo.storage.abs(p.displayPath)];
    try {
      await ExportActions.shareFiles(paths);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _exportZip() async {
    final bytesPath = await runBusy(context, 'Packing ZIP…', (_) => BackupService.exportDocuments(_repo, [widget.docId]));
    if (bytesPath == null) return;
    await ExportActions.shareFiles([bytesPath]);
  }

  Future<void> _menu(String v) async {
    final d = _doc!;
    switch (v) {
      case 'rename':
        await _rename();
      case 'ocr':
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrScreen(docId: d.id)));
      case 'tags':
        await _tags();
      case 'folder':
        await _moveToFolder();
      case 'reorder':
        setState(() => _reorder = !_reorder);
      case 'images':
        await _exportImages();
      case 'zip':
        await _exportZip();
      case 'qr':
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => QrGenerateScreen(initialText: 'scanpro://document/${d.id}?title=${Uri.encodeComponent(d.title)}', title: 'Document reference'),
        ));
      case 'vault':
        await VaultUi.moveToVault(context, ref, d);
        if (mounted && (await _repo.getDocument(d.id)) == null) Navigator.pop(context);
      case 'info':
        await _info();
      case 'delete':
        await _delete();
    }
  }

  Future<void> _info() async {
    final d = _doc!;
    var bytes = 0;
    for (final p in _pages) {
      for (final f in [p.originalPath, p.processedPath]) {
        if (f == null) continue;
        try {
          bytes += await _repo.storage.file(f).length();
        } catch (_) {}
      }
    }
    if (d.pdfPath != null) {
      try {
        bytes += await _repo.storage.file(d.pdfPath!).length();
      } catch (_) {}
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Document info'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pages: ${d.isPdf ? d.pageCount : _pages.length}'),
          Text('Type: ${d.docType ?? '—'}'),
          Text('Created: ${formatDateTime(d.createdAt)}'),
          Text('Modified: ${formatDateTime(d.updatedAt)}'),
          Text('Storage used: ${formatBytes(bytes)}'),
          Text('OCR pages: ${_pages.where((p) => p.hasOcr).length}'),
          if (d.tags.isNotEmpty) Text('Tags: ${d.tags.join(', ')}'),
          const SizedBox(height: 8),
          const Text('Stored privately inside the app. Originals are kept unchanged alongside processed pages.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    if (repo.revision != _rev && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final d = _doc;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (d == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, title: 'Document not found'));
    }
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: _rename, child: Text(d.title, overflow: TextOverflow.ellipsis)),
        actions: [
          IconButton(
            onPressed: () => _repo.setFavourite(d.id, !d.favourite),
            icon: Icon(d.favourite ? Icons.star : Icons.star_border),
            tooltip: d.favourite ? 'Remove from favourites' : 'Add to favourites',
          ),
          if (!d.isPdf)
            IconButton(
              onPressed: _pages.isEmpty
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfExportScreen(document: d, pages: _pages))),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Export PDF',
            ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              if (!d.isPdf) const PopupMenuItem(value: 'ocr', child: Text('Recognise text (OCR)')),
              if (!d.isPdf) PopupMenuItem(value: 'reorder', child: Text(_reorder ? 'Done reordering' : 'Reorder pages')),
              const PopupMenuItem(value: 'tags', child: Text('Tags')),
              const PopupMenuItem(value: 'folder', child: Text('Move to folder')),
              if (!d.isPdf) const PopupMenuItem(value: 'images', child: Text('Share as images')),
              const PopupMenuItem(value: 'zip', child: Text('Export as ZIP')),
              const PopupMenuItem(value: 'qr', child: Text('QR reference')),
              const PopupMenuItem(value: 'vault', child: Text('Move to private vault')),
              const PopupMenuItem(value: 'info', child: Text('Info')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: d.isPdf ? _PdfDocBody(doc: d) : (_reorder ? _reorderList() : _grid(d)),
      floatingActionButton: d.isPdf || _reorder
          ? null
          : FloatingActionButton.extended(onPressed: _showAddSheet, icon: const Icon(Icons.add), label: const Text('Add page')),
    );
  }

  Widget _grid(ScanDocument d) {
    if (_pages.isEmpty) {
      return EmptyState(
        icon: Icons.note_add_outlined,
        title: 'No pages yet',
        action: FilledButton.icon(onPressed: _showAddSheet, icon: const Icon(Icons.add), label: const Text('Add page')),
      );
    }
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${_pages.length} page${_pages.length == 1 ? '' : 's'} · ${relativeTime(d.updatedAt)}',
                style: Theme.of(context).textTheme.bodySmall),
            if (d.docType != null) Chip(label: Text(d.docType!), visualDensity: VisualDensity.compact),
            for (final t in d.tags) Chip(label: Text('#$t'), visualDensity: VisualDensity.compact),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.72, mainAxisSpacing: 10, crossAxisSpacing: 10),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              final p = _pages[i];
              return Semantics(
                label: 'Page ${i + 1}',
                button: true,
                child: InkWell(
                  onTap: () => _openPage(i),
                  borderRadius: BorderRadius.circular(12),
                  child: Card(
                    child: Stack(fit: StackFit.expand, children: [
                      StoredImage(p.thumbPath ?? p.displayPath, cacheWidth: 360),
                      if (p.overlayPath != null) StoredImage(p.overlayPath, fit: BoxFit.cover, cacheWidth: 360),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      ),
                      if (p.hasOcr)
                        const Positioned(right: 6, bottom: 6, child: Icon(Icons.text_snippet, color: Colors.white, size: 18, shadows: [Shadow(blurRadius: 4)])),
                      if (p.flags.isNotEmpty)
                        Positioned(left: 4, top: 4, right: 4, child: FlagChips(p.flags.take(2).toList(), dense: true)),
                    ]),
                  ),
                ),
              );
            },
            childCount: _pages.length,
          ),
        ),
      ),
    ]);
  }

  Widget _reorderList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _pages.length,
      onReorder: (a, b) async {
        final list = [..._pages];
        if (b > a) b--;
        list.insert(b, list.removeAt(a));
        setState(() => _pages = list);
        await _repo.reorderPages(widget.docId, list.map((e) => e.id).toList());
      },
      itemBuilder: (ctx, i) {
        final p = _pages[i];
        return Card(
          key: ValueKey(p.id),
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: SizedBox(width: 44, height: 56, child: StoredImage(p.thumbPath ?? p.displayPath, cacheWidth: 120)),
            title: Text('Page ${i + 1}'),
            subtitle: p.flags.isEmpty ? null : FlagChips(p.flags, dense: true),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.rotate_right), tooltip: 'Rotate', onPressed: () => runBusy(context, 'Rotating…', (_) => _repo.rotatePage(p, 90))),
              IconButton(icon: const Icon(Icons.copy), tooltip: 'Duplicate', onPressed: () => runBusy(context, 'Duplicating…', (_) => _repo.duplicatePage(p))),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () async {
                  if (await confirm(context, 'Delete page ${i + 1}?', 'The page and its original are removed.', ok: 'Delete', destructive: true)) {
                    await _repo.deletePage(p);
                  }
                },
              ),
              ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
            ]),
          ),
        );
      },
    );
  }
}

/// Body for documents that are stored as PDF files (imported or derived).
class _PdfDocBody extends ConsumerStatefulWidget {
  final ScanDocument doc;
  const _PdfDocBody({required this.doc});

  @override
  ConsumerState<_PdfDocBody> createState() => _PdfDocBodyState();
}

class _PdfDocBodyState extends ConsumerState<_PdfDocBody> {
  LoadedPdf? _pdf;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await PdfLibrary.readDocPdf(ref.read(repositoryProvider), widget.doc);
      if (!mounted) return;
      final l = await PdfLibrary.open(context, bytes, widget.doc.title);
      if (!mounted) return;
      setState(() {
        _pdf = l;
        if (l == null) _error = 'Password required to open this PDF.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _pdf;
    if (_error != null) {
      return EmptyState(icon: Icons.lock_outline, title: 'Cannot open PDF', message: _error, action: FilledButton(onPressed: _load, child: const Text('Try again')));
    }
    if (l == null) return const Center(child: CircularProgressIndicator());
    final actions = <(IconData, String, VoidCallback)>[
      (Icons.open_in_full, 'View', () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PdfViewerScreen(bytes: l.bytes, title: widget.doc.title, offerSaveToLibrary: false, password: l.password)))),
      (Icons.view_module_outlined, 'Organise', () => PdfTools.organize(context, ref, l, parentId: widget.doc.id)),
      (Icons.compress, 'Compress', () => PdfTools.compress(context, ref, l, parentId: widget.doc.id)),
      (Icons.call_split, 'Split / extract', () => PdfTools.split(context, ref, l, parentId: widget.doc.id)),
      (Icons.lock_outline, l.password == null ? 'Protect' : 'Change password', () => PdfTools.protect(context, ref, l, parentId: widget.doc.id)),
      if (l.password != null) (Icons.lock_open, 'Remove password', () => PdfTools.unlock(context, ref, l, parentId: widget.doc.id)),
      (Icons.image_outlined, 'To images', () => PdfTools.toImages(context, ref, l)),
      (Icons.text_snippet_outlined, 'Text', () => PdfTools.showText(context, l)),
      (Icons.share_outlined, 'Share', () => ExportActions.shareBytes(l.bytes, Naming.withExtension(widget.doc.title, 'pdf'), mime: 'application/pdf')),
      (Icons.print_outlined, 'Print', () => ExportActions.printPdf(l.bytes, widget.doc.title)),
      (Icons.save_alt, 'Save to device', () => ExportActions.saveBytes(l.bytes, Naming.withExtension(widget.doc.title, 'pdf'))),
    ];
    return Column(children: [
      SizedBox(
        height: 92,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            for (final a in actions)
              SizedBox(
                width: 84,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: a.$3,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(a.$1),
                    const SizedBox(height: 4),
                    Text(a.$2, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 11)),
                  ]),
                ),
              ),
          ],
        ),
      ),
      ListTile(
        dense: true,
        title: Text('${l.info.pageCount} pages · ${formatBytes(l.bytes.length)}${l.password != null ? ' · protected' : ''}'),
        subtitle: const Text('Original PDF is kept unchanged. Tools create new versions.'),
      ),
      Expanded(
        child: l.password != null
            ? const EmptyState(icon: Icons.lock_outline, title: 'Protected PDF', message: 'Tap View to preview with the password you entered.')
            : PdfPreview(
                build: (_) async => l.bytes,
                useActions: false,
                canChangeOrientation: false,
                canChangePageFormat: false,
                canDebug: false,
              ),
      ),
    ]);
  }
}
