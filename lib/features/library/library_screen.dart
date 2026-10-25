import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../core/storage.dart';
import '../../shared/widgets.dart';
import '../backup/backup_screen.dart';
import '../pdf/pdf_library.dart';
import '../scanner/scan_flow.dart';
import 'document_screen.dart';
import 'trash_screen.dart';

/// All documents: search (names, tags and OCR text), filters, folders,
/// tags, sorting and grid/list views.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _filter = 'all'; // all | fav | recent | pdf | sheet | folder:<id> | tag:<name>
  String _sort = 'updated';
  Future<_LibData>? _future;
  int _rev = -1;

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  DocumentRepository get _repo => ref.read(repositoryProvider);

  Future<_LibData> _loadData() async {
    final repo = _repo;
    final folders = await repo.listFolders();
    final tags = await repo.allTags();
    if (_query.trim().isNotEmpty) {
      final hits = await repo.search(_query);
      return _LibData(const [], hits, folders, tags);
    }
    List<ScanDocument> docs;
    if (_filter == 'fav') {
      docs = await repo.listDocuments(favouritesOnly: true, sort: _sort);
    } else if (_filter == 'recent') {
      docs = await repo.listDocuments(recentOpened: true, sort: 'opened', limit: 30);
    } else if (_filter == 'pdf') {
      docs = await repo.listDocuments(kind: DocKind.pdf.name, sort: _sort);
    } else if (_filter == 'sheet') {
      docs = await repo.listDocuments(kind: DocKind.photoSheet.name, sort: _sort);
    } else if (_filter.startsWith('folder:')) {
      docs = await repo.listDocuments(folderId: _filter.substring(7), sort: _sort);
    } else if (_filter.startsWith('tag:')) {
      docs = await repo.listDocuments(tag: _filter.substring(4), sort: _sort);
    } else {
      docs = await repo.listDocuments(sort: _sort);
    }
    return _LibData(docs, null, folders, tags);
  }

  void _reload() => setState(() => _future = _loadData());

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _query = v;
      _reload();
    });
  }

  Future<void> _importPdf() async {
    try {
      final loaded = await PdfLibrary.pickAndOpen(context, multiple: true);
      if (loaded.isEmpty || !mounted) return;
      final repo = _repo;
      String? lastId;
      await runBusy<void>(context, 'Importing PDF…', (ctl) async {
        for (var i = 0; i < loaded.length; i++) {
          ctl.update('Importing ${i + 1} of ${loaded.length}…', (i + 1) / loaded.length);
          final d = await PdfLibrary.saveToLibrary(repo, loaded[i].bytes, loaded[i].name, password: loaded[i].password);
          lastId = d.id;
        }
      });
      if (lastId != null && mounted && loaded.length == 1) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: lastId!)));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  void _showImport() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Scan document'),
            onTap: () {
              Navigator.pop(ctx);
              ScanFlow.showAddSheet(context, ref);
            },
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('Import PDF'),
            subtitle: const Text('Kept unchanged; existing text stays searchable'),
            onTap: () {
              Navigator.pop(ctx);
              _importPdf();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Import images'),
            onTap: () {
              Navigator.pop(ctx);
              ScanFlow.importImages(context, ref);
            },
          ),
          ListTile(
            leading: const Icon(Icons.unarchive_outlined),
            title: const Text('Import ZIP backup'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupScreen()));
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _folderMenu(Folder f) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit), title: const Text('Rename folder'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete folder (keeps documents)'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (v == 'rename' && mounted) {
      final name = await promptText(context, 'Rename folder', initial: f.name);
      if (name != null && name.isNotEmpty) await _repo.renameFolder(f.id, name);
    } else if (v == 'delete') {
      await _repo.deleteFolder(f.id);
      if (_filter == 'folder:${f.id}') setState(() => _filter = 'all');
    }
  }

  Future<void> _docMenu(ScanDocument d) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w600))),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
            leading: Icon(d.favourite ? Icons.star : Icons.star_border),
            title: Text(d.favourite ? 'Remove from favourites' : 'Add to favourites'),
            onTap: () => Navigator.pop(ctx, 'fav'),
          ),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    switch (v) {
      case 'rename':
        {
          final name = await promptText(context, 'Rename', initial: d.title);
          if (name != null && name.isNotEmpty) await _repo.rename(d.id, name);
        }
      case 'fav':
        await _repo.setFavourite(d.id, !d.favourite);
      case 'delete':
        await _repo.softDelete(d.id);
        if (mounted) {
          showSnack(context, 'Moved to Recently deleted', action: SnackBarAction(label: 'Undo', onPressed: () => _repo.restore(d.id)));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final settings = ref.watch(settingsProvider);
    if (_future == null || repo.revision != _rev) {
      _rev = repo.revision;
      _future = _loadData();
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        actions: [
          IconButton(
            tooltip: settings.gridView ? 'List view' : 'Grid view',
            onPressed: () => settings.setGridView(!settings.gridView),
            icon: Icon(settings.gridView ? Icons.view_list_outlined : Icons.grid_view),
          ),
          PopupMenuButton<String>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) {
              _sort = v;
              _reload();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'updated', child: Text('Last modified')),
              PopupMenuItem(value: 'created', child: Text('Date created')),
              PopupMenuItem(value: 'name', child: Text('Name')),
            ],
          ),
          IconButton(
            tooltip: 'Recently deleted',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TrashScreen())),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SearchBar(
              controller: _search,
              hintText: 'Search names, tags and text in documents',
              leading: const Icon(Icons.search),
              trailing: [
                if (_search.text.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      _search.clear();
                      _query = '';
                      _reload();
                    },
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                  ),
              ],
              onChanged: (v) {
                setState(() {});
                _onSearch(v);
              },
              elevation: const WidgetStatePropertyAll(0),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _showImport, icon: const Icon(Icons.add), label: const Text('New')),
      body: FutureBuilder<_LibData>(
        future: _future,
        builder: (ctx, snap) {
          final data = snap.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          return Column(children: [
            if (_query.isEmpty) _filters(data),
            Expanded(child: data.hits != null ? _results(data.hits!) : _docs(data.docs, settings.gridView)),
          ]);
        },
      ),
    );
  }

  Widget _filters(_LibData data) {
    Widget chip(String id, String label, {IconData? icon, VoidCallback? onLong}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onLongPress: onLong,
            child: FilterChip(
              avatar: icon == null ? null : Icon(icon, size: 16),
              label: Text(label),
              selected: _filter == id,
              onSelected: (_) {
                _filter = id;
                _reload();
              },
            ),
          ),
        );
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
        chip('all', 'All'),
        chip('fav', 'Favourites', icon: Icons.star),
        chip('recent', 'Recent', icon: Icons.history),
        chip('pdf', 'PDFs', icon: Icons.picture_as_pdf_outlined),
        chip('sheet', 'Photo sheets', icon: Icons.portrait_outlined),
        for (final f in data.folders) chip('folder:${f.id}', f.name, icon: Icons.folder_outlined, onLong: () => _folderMenu(f)),
        for (final t in data.tags) chip('tag:$t', '#$t'),
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ActionChip(
            avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('Folder'),
            onPressed: () async {
              final name = await promptText(context, 'New folder');
              if (name != null && name.isNotEmpty) await _repo.createFolder(name);
            },
          ),
        ),
      ]),
    );
  }

  Widget _docs(List<ScanDocument> docs, bool grid) {
    if (docs.isEmpty) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: _filter == 'all' ? 'No documents yet' : 'Nothing here',
        message: _filter == 'all' ? 'Scan a document or import images and PDFs to get started.' : null,
        action: _filter == 'all' ? FilledButton.icon(onPressed: _showImport, icon: const Icon(Icons.add), label: const Text('Add document')) : null,
      );
    }
    if (!grid) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
        itemCount: docs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (ctx, i) => DocumentListTile(doc: docs[i], onLongPress: () => _docMenu(docs[i])),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, childAspectRatio: 0.68, mainAxisSpacing: 12, crossAxisSpacing: 12),
      itemCount: docs.length,
      itemBuilder: (ctx, i) => DocumentCard(doc: docs[i], onLongPress: () => _docMenu(docs[i])),
    );
  }

  Widget _results(List<SearchHit> hits) {
    if (hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        message: ref.read(settingsProvider).searchIndexing
            ? 'Text inside scans is searchable after OCR has been run on them.'
            : 'Text search is disabled in Settings.',
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
      itemCount: hits.length,
      itemBuilder: (ctx, i) {
        final h = hits[i];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: SizedBox(width: 44, height: 56, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: StoredImage(h.document.coverThumb, cacheWidth: 120))),
            title: Text(h.document.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: h.snippet == null
                ? Text(h.titleMatch ? 'Name or tag match' : '')
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (h.pageIndex != null) Text('Page ${h.pageIndex! + 1}', style: TextStyle(color: scheme.primary, fontSize: 12)),
                    _Snippet(h.snippet!),
                  ]),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DocumentScreen(docId: h.document.id, initialPage: h.pageIndex),
            )),
          ),
        );
      },
    );
  }
}

class _LibData {
  final List<ScanDocument> docs;
  final List<SearchHit>? hits;
  final List<Folder> folders;
  final List<String> tags;
  _LibData(this.docs, this.hits, this.folders, this.tags);
}

/// Renders an FTS snippet, bolding text between [ and ].
class _Snippet extends StatelessWidget {
  final String text;
  const _Snippet(this.text);

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\[([^\]]*)\]');
    var last = 0;
    final hl = TextStyle(fontWeight: FontWeight.w700, backgroundColor: Theme.of(context).colorScheme.primaryContainer);
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(1), style: hl));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(children: spans, style: Theme.of(context).textTheme.bodySmall), maxLines: 3, overflow: TextOverflow.ellipsis);
  }
}

class DocumentCard extends StatelessWidget {
  final ScanDocument doc;
  final VoidCallback? onLongPress;
  const DocumentCard({super.key, required this.doc, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: doc.id))),
        onLongPress: onLongPress,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              doc.isPdf && doc.coverThumb == null
                  ? Container(color: t.colorScheme.surfaceContainerHighest, child: Icon(Icons.picture_as_pdf, size: 48, color: t.colorScheme.primary))
                  : StoredImage(doc.coverThumb, cacheWidth: 400),
              if (doc.favourite) const Positioned(right: 6, top: 6, child: Icon(Icons.star, color: Colors.amber, shadows: [Shadow(blurRadius: 4)])),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text('${doc.pageCount} p · ${relativeTime(doc.updatedAt)}', style: t.textTheme.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }
}

class DocumentListTile extends StatelessWidget {
  final ScanDocument doc;
  final VoidCallback? onLongPress;
  const DocumentListTile({super.key, required this.doc, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: doc.id))),
        onLongPress: onLongPress,
        leading: SizedBox(
          width: 44,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: doc.isPdf && doc.coverThumb == null
                ? Container(color: t.colorScheme.surfaceContainerHighest, child: Icon(Icons.picture_as_pdf, color: t.colorScheme.primary))
                : StoredImage(doc.coverThumb, cacheWidth: 120),
          ),
        ),
        title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          '${doc.pageCount} page${doc.pageCount == 1 ? '' : 's'}',
          relativeTime(doc.updatedAt),
          if (doc.docType != null) doc.docType!,
        ].join(' · ')),
        trailing: doc.favourite ? const Icon(Icons.star, color: Colors.amber) : null,
      ),
    );
  }
}
