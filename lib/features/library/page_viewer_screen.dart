import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../shared/widgets.dart';
import '../annotate/annotate_screen.dart';
import '../editor/page_editor_screen.dart';
import '../ocr/ocr_screen.dart';

/// Full-screen page viewer with quick actions (edit, rotate, OCR,
/// annotate, duplicate, delete) and an original/processed toggle.
class PageViewerScreen extends ConsumerStatefulWidget {
  final String docId;
  final int initialIndex;
  const PageViewerScreen({super.key, required this.docId, this.initialIndex = 0});

  @override
  ConsumerState<PageViewerScreen> createState() => _PageViewerScreenState();
}

class _PageViewerScreenState extends ConsumerState<PageViewerScreen> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  List<DocPage> _pages = const [];
  late int _index = widget.initialIndex;
  bool _showOriginal = false;
  int _rev = -1;

  DocumentRepository get _repo => ref.read(repositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final pages = await _repo.getPages(widget.docId);
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _rev = _repo.revision;
      if (_index >= pages.length) _index = pages.isEmpty ? 0 : pages.length - 1;
    });
    if (pages.isEmpty && mounted) Navigator.pop(context);
  }

  DocPage? get _page => _pages.isEmpty ? null : _pages[_index < 0 ? 0 : (_index >= _pages.length ? _pages.length - 1 : _index)];

  Future<void> _action(String a) async {
    final p = _page;
    if (p == null) return;
    switch (a) {
      case 'edit':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PageEditorScreen(page: p)));
      case 'rotate':
        await runBusy(context, 'Rotating…', (_) => _repo.rotatePage(p, 90));
      case 'ocr':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrScreen(docId: widget.docId, initialPageId: p.id)));
      case 'annotate':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnnotateScreen(page: p)));
      case 'duplicate':
        await runBusy(context, 'Duplicating…', (_) => _repo.duplicatePage(p));
      case 'delete':
        {
          final ok = await confirm(context, 'Delete this page?', 'The page and its original capture are removed.', ok: 'Delete', destructive: true);
          if (ok) await _repo.deletePage(p);
        }
      case 'flags':
        for (final f in p.flags) {
          await _repo.clearPageFlag(p, f);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    if (repo.revision != _rev) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    final p = _page;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_pages.isEmpty ? '' : 'Page ${_index + 1} of ${_pages.length}'),
        actions: [
          IconButton(
            tooltip: _showOriginal ? 'Show processed' : 'Show original capture',
            onPressed: () => setState(() => _showOriginal = !_showOriginal),
            icon: Icon(_showOriginal ? Icons.auto_fix_high : Icons.image_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: _action,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'duplicate', child: Text('Duplicate page')),
              if (p != null && p.flags.isNotEmpty) const PopupMenuItem(value: 'flags', child: Text('Dismiss quality warnings')),
              const PopupMenuItem(value: 'delete', child: Text('Delete page')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (p != null && p.flags.isNotEmpty)
          Padding(padding: const EdgeInsets.all(8), child: FlagChips(p.flags)),
        Expanded(
          child: PageView.builder(
            controller: _pc,
            itemCount: _pages.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) {
              final pg = _pages[i];
              return InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: Stack(children: [
                    StoredImage(_showOriginal ? pg.originalPath : pg.displayPath, fit: BoxFit.contain, key: ValueKey('${pg.displayPath}$_showOriginal')),
                    if (!_showOriginal && pg.overlayPath != null) Positioned.fill(child: StoredImage(pg.overlayPath, fit: BoxFit.contain)),
                  ]),
                ),
              );
            },
          ),
        ),
        if (_showOriginal)
          const Padding(
            padding: EdgeInsets.all(6),
            child: Text('Original capture (never modified)', style: TextStyle(color: Colors.white70)),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _btn(Icons.tune, 'Edit', 'edit'),
            _btn(Icons.rotate_right, 'Rotate', 'rotate'),
            _btn(Icons.text_snippet_outlined, 'OCR', 'ocr'),
            _btn(Icons.draw_outlined, 'Annotate', 'annotate'),
          ]),
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String label, String action) => TextButton(
        onPressed: () => _action(action),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      );
}
