import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../core/storage.dart' show friendlyError;
import '../../../shared/widgets.dart';
import '../../pdf/pdf_service.dart';
import '../../pdf_editor/engine/engine_worker.dart';
import '../../pdf_editor/engine/pdfium_engine.dart' show PdfOutlineItem, PdfSearchHit;
import '../suite.dart';
import 'page_cache.dart';
import 'reader_store.dart';

enum ReaderLayout { continuous, single, twoPage, book }

enum ReaderTheme { light, dark, sepia, custom }

const _invert = ColorFilter.matrix([-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]);
const _sepia = ColorFilter.matrix([0.95, 0, 0, 0, 0, 0, 0.88, 0, 0, 0, 0, 0, 0.72, 0, 0, 0, 0, 0, 1, 0]);

/// Distraction-free PDF reader: continuous, single, two-page and book
/// layouts, light/dark/sepia/custom backgrounds, thumbnails, outline,
/// bookmarks, search, jump to page, text copy, read aloud and resume where
/// you left off.
class ReaderScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final int? initialPage;
  const ReaderScreen({super.key, required this.bytes, required this.title, this.password, this.initialPage});

  /// Opens [bytes] in the reader, asking for a password when needed.
  static Future<void> open(BuildContext context, Uint8List bytes, String title, {String? password}) async {
    var pw = password;
    if (pw == null) {
      try {
        PdfService.inspect(PdfSource(bytes));
      } on PdfPasswordRequired {
        for (var i = 0; i < 5 && pw == null; i++) {
          if (!context.mounted) return;
          final v = await promptText(context, i == 0 ? '"$title" is password protected' : 'Incorrect password, try again', hint: 'PDF password', obscure: true, ok: 'Open');
          if (v == null) return;
          try {
            PdfService.inspect(PdfSource(bytes, password: v));
            pw = v;
          } on PdfPasswordRequired {
            continue;
          }
        }
        if (pw == null) return;
      } catch (_) {
        // PDFium may still open files Syncfusion rejects; let the reader try.
      }
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(bytes: bytes, title: title, password: pw)));
  }

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  HostSession? _session;
  PageRenderCache? _cache;
  ReaderStore? _store;
  ReaderEntry? _entry;
  Object? _error;
  var _layout = ReaderLayout.continuous;
  var _theme = ReaderTheme.light;
  var _custom = const Color(0xFFE8F0E8);
  var _page = 0;
  var _fullscreen = false;
  final _scroll = ScrollController();
  PageController? _pager;
  List<PdfOutlineItem>? _outline;
  Map<int, List<Rect>> _highlights = {};
  Timer? _saveTimer;

  // Read aloud
  FlutterTts? _tts;
  var _speaking = false;
  var _rate = 0.5;

  @override
  void initState() {
    super.initState();
    _open();
    _scroll.addListener(_onScroll);
  }

  Future<void> _open() async {
    try {
      final suite = await DocSuite.get();
      final s = await suite.host.open(widget.bytes, password: widget.password);
      final cache = await PageRenderCache.open(s);
      final store = await ReaderStore.get();
      final entry = await store.opened(widget.bytes, widget.title, encrypted: s.encrypted);
      if (!mounted) {
        s.close();
        return;
      }
      setState(() {
        _session = s;
        _cache = cache;
        _store = store;
        _entry = entry;
        _page = (widget.initialPage ?? entry.lastPage).clamp(0, s.pageCount - 1);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(_page, animate: false));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persist();
    _tts?.stop();
    _cache?.dispose();
    _session?.close();
    _scroll.dispose();
    _pager?.dispose();
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _persist() {
    final e = _entry;
    if (e == null) return;
    e.lastPage = _page;
    _store?.save();
  }

  void _setPage(int p) {
    if (p == _page) return;
    setState(() => _page = p);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _persist);
  }

  // ---- layout helpers -----------------------------------------------------

  static const _gap = 8.0;

  double _pageWidth(BoxConstraints c, int page) => c.maxWidth - 16;

  List<List<int>> get _spreads {
    final n = _cache!.pageCount;
    switch (_layout) {
      case ReaderLayout.twoPage:
        return [for (var i = 0; i < n; i += 2) [i, if (i + 1 < n) i + 1]];
      case ReaderLayout.book:
        return [
          [0],
          for (var i = 1; i < n; i += 2) [i, if (i + 1 < n) i + 1]
        ];
      default:
        return [for (var i = 0; i < n; i++) [i]];
    }
  }

  int _spreadOf(int page) => _spreads.indexWhere((s) => s.contains(page));

  double? _lastWidth;

  double _offsetOf(int page) {
    final w = (_lastWidth ?? 360) - 16;
    var y = 0.0;
    for (var i = 0; i < page; i++) {
      final s = _cache!.sizes[i];
      y += w * s.height / s.width + _gap;
    }
    return y;
  }

  void _onScroll() {
    if (_layout != ReaderLayout.continuous || _cache == null) return;
    final w = (_lastWidth ?? 360) - 16;
    final y = _scroll.offset + 80;
    var acc = 0.0;
    for (var i = 0; i < _cache!.pageCount; i++) {
      final s = _cache!.sizes[i];
      acc += w * s.height / s.width + _gap;
      if (acc > y) {
        _setPage(i);
        return;
      }
    }
  }

  void _goTo(int page, {bool animate = true}) {
    if (_cache == null) return;
    page = page.clamp(0, _cache!.pageCount - 1);
    _setPage(page);
    if (_layout == ReaderLayout.continuous) {
      if (_scroll.hasClients) {
        final target = _offsetOf(page).clamp(0.0, _scroll.position.maxScrollExtent);
        animate ? _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut) : _scroll.jumpTo(target);
      }
    } else if (_pager?.hasClients ?? false) {
      _pager!.jumpToPage(_spreadOf(page));
    }
  }

  void _setLayout(ReaderLayout l) {
    final page = _page;
    _pager?.dispose();
    _pager = l == ReaderLayout.continuous ? null : PageController(initialPage: 0);
    setState(() => _layout = l);
    WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(page, animate: false));
  }

  // ---- theme ----------------------------------------------------------------

  Color get _background => switch (_theme) {
        ReaderTheme.light => const Color(0xFFE0E0E0),
        ReaderTheme.dark => const Color(0xFF121212),
        ReaderTheme.sepia => const Color(0xFFE9DFC8),
        ReaderTheme.custom => _custom,
      };

  ColorFilter? get _filter => switch (_theme) {
        ReaderTheme.dark => _invert,
        ReaderTheme.sepia => _sepia,
        _ => null,
      };

  // ---- actions ------------------------------------------------------------

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    await SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  Future<void> _jump() async {
    final v = await promptText(context, 'Go to page', hint: '1 – ${_cache!.pageCount}', ok: 'Go', keyboard: TextInputType.number);
    final n = int.tryParse(v ?? '');
    if (n == null) return;
    if (n < 1 || n > _cache!.pageCount) {
      if (mounted) showSnack(context, 'Choose a page from 1 to ${_cache!.pageCount}.');
      return;
    }
    _goTo(n - 1);
  }

  bool get _bookmarked => _entry?.bookmarks.any((b) => b.page == _page) ?? false;

  Future<void> _toggleBookmark() async {
    final e = _entry!;
    if (_bookmarked) {
      e.bookmarks.removeWhere((b) => b.page == _page);
    } else {
      final label = await promptText(context, 'Bookmark page ${_page + 1}', hint: 'Label (optional)', ok: 'Add');
      if (label == null) return;
      e.bookmarks
        ..add(ReaderBookmark(_page, label.trim()))
        ..sort((a, b) => a.page.compareTo(b.page));
    }
    await _store!.save();
    setState(() {});
  }

  Future<void> _search() async {
    final hit = await showSearch<PdfSearchHit?>(context: context, delegate: _PdfSearch(_session!));
    if (hit == null) return;
    setState(() => _highlights = {hit.page: hit.rects});
    _goTo(hit.page);
  }

  Future<void> _showText() async {
    final text = await _session!.call<String>('pageText', [_page]);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, sc) => Column(children: [
          ListTile(
            title: Text('Text on page ${_page + 1}'),
            subtitle: const Text('Select text to copy part of it'),
            trailing: TextButton.icon(
              onPressed: text.trim().isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      Navigator.pop(ctx);
                      showSnack(context, 'Page text copied');
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy all'),
            ),
          ),
          Expanded(
            child: text.trim().isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('This page has no text layer (it is probably a scan). Use Extract text (OCR) or the PDF editor\'s OCR to recognise it.'),
                  )
                : SingleChildScrollView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), child: SelectableText(text)),
          ),
        ]),
      ),
    );
  }

  Future<void> _speak() async {
    if (_speaking) {
      await _tts?.stop();
      setState(() => _speaking = false);
      return;
    }
    final tts = _tts ??= FlutterTts();
    try {
      await tts.setSpeechRate(_rate);
      await tts.awaitSpeakCompletion(true);
    } catch (_) {}
    setState(() => _speaking = true);
    var page = _page;
    var spokeAny = false;
    while (mounted && _speaking && page < _cache!.pageCount) {
      final text = (await _session!.call<String>('pageText', [page])).trim();
      if (text.isNotEmpty) {
        spokeAny = true;
        if (page != _page) _goTo(page);
        // Engines limit utterance length; speak paragraph-sized chunks.
        for (final chunk in _chunks(text)) {
          if (!mounted || !_speaking) break;
          try {
            await tts.speak(chunk);
          } catch (_) {
            if (mounted) showSnack(context, 'Read aloud is not available. Install or enable a text-to-speech engine in Android settings.');
            setState(() => _speaking = false);
            return;
          }
        }
      }
      page++;
    }
    if (mounted) {
      if (!spokeAny) showSnack(context, 'There is no text to read from this page on (scanned pages need OCR first).');
      setState(() => _speaking = false);
    }
  }

  static Iterable<String> _chunks(String text) sync* {
    final parts = text.replaceAll(RegExp(r'-\r?\n'), '').split(RegExp(r'(?<=[.!?])\s+|\n{2,}'));
    var buf = StringBuffer();
    for (final p in parts) {
      if (buf.length + p.length > 900 && buf.isNotEmpty) {
        yield buf.toString();
        buf = StringBuffer();
      }
      buf
        ..write(p.replaceAll(RegExp(r'\s+'), ' '))
        ..write(' ');
    }
    if (buf.isNotEmpty) yield buf.toString();
  }

  Future<void> _themeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Layout', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final l in ReaderLayout.values)
                  ChoiceChip(
                    label: Text(switch (l) {
                      ReaderLayout.continuous => 'Continuous',
                      ReaderLayout.single => 'Single page',
                      ReaderLayout.twoPage => 'Two pages',
                      ReaderLayout.book => 'Book',
                    }),
                    selected: _layout == l,
                    onSelected: (_) {
                      _setLayout(l);
                      set(() {});
                    },
                  ),
              ]),
              const SizedBox(height: 16),
              const Text('Background', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final t in ReaderTheme.values.where((t) => t != ReaderTheme.custom))
                  ChoiceChip(
                    label: Text(switch (t) { ReaderTheme.light => 'Light', ReaderTheme.dark => 'Dark (inverted)', ReaderTheme.sepia => 'Sepia', _ => '' }),
                    selected: _theme == t,
                    onSelected: (_) {
                      setState(() => _theme = t);
                      set(() {});
                    },
                  ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 10, children: [
                for (final c in const [Color(0xFFE8F0E8), Color(0xFFDDE7F2), Color(0xFFF3E5F5), Color(0xFF37474F), Color(0xFFFFFFFF)])
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _theme = ReaderTheme.custom;
                        _custom = c;
                      });
                      set(() {});
                    },
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.black26,
                      child: CircleAvatar(radius: _theme == ReaderTheme.custom && _custom == c ? 11 : 14, backgroundColor: c),
                    ),
                  ),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                const Text('Reading speed'),
                Expanded(
                  child: Slider(
                    value: _rate,
                    min: 0.2,
                    max: 1.0,
                    onChanged: (v) {
                      setState(() => _rate = v);
                      set(() {});
                    },
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _navigatorSheet() async {
    _outline ??= await _session!.call<List<PdfOutlineItem>>('outline');
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DefaultTabController(
        length: 3,
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.75,
          child: Column(children: [
            const TabBar(tabs: [Tab(text: 'Pages'), Tab(text: 'Contents'), Tab(text: 'Bookmarks')]),
            Expanded(
              child: TabBarView(children: [
                GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120, childAspectRatio: 0.66, crossAxisSpacing: 10, mainAxisSpacing: 10),
                  itemCount: _cache!.pageCount,
                  itemBuilder: (c, i) => GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _goTo(i);
                    },
                    child: Column(children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(border: Border.all(color: i == _page ? Theme.of(c).colorScheme.primary : Colors.black12, width: i == _page ? 2 : 1)),
                          child: FittedBox(child: RenderedPageView(cache: _cache!, page: i, width: 100)),
                        ),
                      ),
                      Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
                _outline!.isEmpty
                    ? const Center(child: Text('This PDF has no table of contents.'))
                    : ListView(children: [
                        for (final o in _outline!)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.only(left: 16.0 + 16 * o.level, right: 16),
                            title: Text(o.title),
                            trailing: o.page == null ? null : Text('${o.page! + 1}'),
                            enabled: o.page != null,
                            onTap: () {
                              Navigator.pop(ctx);
                              _goTo(o.page!);
                            },
                          ),
                      ]),
                _entry!.bookmarks.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No bookmarks yet. Tap the bookmark icon to mark a page.')))
                    : ListView(children: [
                        for (final b in _entry!.bookmarks)
                          ListTile(
                            leading: const Icon(Icons.bookmark),
                            title: Text(b.label.isEmpty ? 'Page ${b.page + 1}' : b.label),
                            subtitle: b.label.isEmpty ? null : Text('Page ${b.page + 1}'),
                            onTap: () {
                              Navigator.pop(ctx);
                              _goTo(b.page);
                            },
                          ),
                      ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _recent() async {
    final list = _store!.recent().where((e) => e.key != _entry!.key).toList();
    if (list.isEmpty) return showSnack(context, 'No other recently read documents.');
    final pick = await showModalBottomSheet<ReaderEntry>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Recently read', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final e in list)
            ListTile(
              leading: Icon(e.encrypted ? Icons.lock_outline : Icons.menu_book_outlined),
              title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('Page ${e.lastPage + 1}'),
              onTap: () => Navigator.pop(ctx, e),
            ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    final bytes = await File(_store!.fileFor(pick.key)).readAsBytes();
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    await ReaderScreen.open(nav.context, bytes, pick.title);
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cache = _cache;
    final dark = _theme == ReaderTheme.dark || (_theme == ReaderTheme.custom && _custom.computeLuminance() < 0.3);
    return Theme(
      data: dark ? ThemeData.dark(useMaterial3: true) : Theme.of(context),
      child: Scaffold(
        backgroundColor: _background,
        appBar: _fullscreen
            ? null
            : AppBar(
                title: Text(widget.title, overflow: TextOverflow.ellipsis),
                actions: cache == null
                    ? null
                    : [
                        IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: _search),
                        IconButton(
                          tooltip: _bookmarked ? 'Remove bookmark' : 'Bookmark this page',
                          icon: Icon(_bookmarked ? Icons.bookmark : Icons.bookmark_border),
                          onPressed: _toggleBookmark,
                        ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            switch (v) {
                              case 'jump':
                                _jump();
                              case 'text':
                                _showText();
                              case 'recent':
                                _recent();
                              case 'full':
                                _toggleFullscreen();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'jump', child: Text('Go to page…')),
                            PopupMenuItem(value: 'text', child: Text('Copy text from this page')),
                            PopupMenuItem(value: 'recent', child: Text('Recently read…')),
                            PopupMenuItem(value: 'full', child: Text('Full screen')),
                          ],
                        ),
                      ],
              ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('This PDF could not be opened: ${friendlyError(_error!)}')))
            : cache == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (ctx, c) {
                    _lastWidth = c.maxWidth;
                    return GestureDetector(
                      onLongPress: _fullscreen ? _toggleFullscreen : null,
                      child: _layout == ReaderLayout.continuous ? _continuous(c) : _paged(c),
                    );
                  }),
        bottomNavigationBar: _fullscreen || cache == null
            ? null
            : BottomAppBar(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  IconButton(tooltip: 'Pages, contents and bookmarks', icon: const Icon(Icons.view_list_outlined), onPressed: _navigatorSheet),
                  IconButton(tooltip: 'View options', icon: const Icon(Icons.tune), onPressed: _themeSheet),
                  IconButton(
                    tooltip: _speaking ? 'Stop reading aloud' : 'Read aloud from this page',
                    icon: Icon(_speaking ? Icons.stop_circle_outlined : Icons.record_voice_over_outlined),
                    onPressed: _speak,
                  ),
                  const Spacer(),
                  TextButton(onPressed: _jump, child: Text('${_page + 1} / ${cache.pageCount}')),
                  IconButton(tooltip: 'Full screen (long-press to exit)', icon: const Icon(Icons.fullscreen), onPressed: _toggleFullscreen),
                ]),
              ),
      ),
    );
  }

  Widget _continuous(BoxConstraints c) {
    final cache = _cache!;
    return Scrollbar(
      controller: _scroll,
      interactive: true,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        itemCount: cache.pageCount,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(bottom: _gap),
          child: GestureDetector(
            onDoubleTap: () {
              _setPage(i);
              _setLayout(ReaderLayout.single);
            },
            child: RenderedPageView(cache: cache, page: i, width: _pageWidth(c, i), filter: _filter, highlights: _highlights[i] ?? const []),
          ),
        ),
      ),
    );
  }

  Widget _paged(BoxConstraints c) {
    final cache = _cache!;
    final spreads = _spreads;
    _pager ??= PageController(initialPage: _spreadOf(_page));
    return PageView.builder(
      controller: _pager,
      itemCount: spreads.length,
      onPageChanged: (i) => _setPage(spreads[i].first),
      itemBuilder: (ctx, i) {
        final pages = spreads[i];
        // Fit the spread inside the screen.
        final total = pages.fold<double>(0, (w, p) => w + cache.sizes[p].width);
        final maxH = pages.fold<double>(0, (h, p) => h > cache.sizes[p].height ? h : cache.sizes[p].height);
        final k = [(c.maxWidth - 16 - (pages.length - 1) * 4) / total, (c.maxHeight - 16) / maxH].reduce((a, b) => a < b ? a : b);
        return InteractiveViewer(
          maxScale: 5,
          child: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final p in pages)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: RenderedPageView(cache: cache, page: p, width: cache.sizes[p].width * k, filter: _filter, highlights: _highlights[p] ?? const []),
                ),
            ]),
          ),
        );
      },
    );
  }
}

class _PdfSearch extends SearchDelegate<PdfSearchHit?> {
  final HostSession session;
  _PdfSearch(this.session) : super(searchFieldLabel: 'Search in document');

  String? _lastQuery;
  Future<List<PdfSearchHit>>? _future;

  @override
  List<Widget>? buildActions(BuildContext context) => [if (query.isNotEmpty) IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(icon: const BackButtonIcon(), onPressed: () => close(context, null));

  @override
  Widget buildSuggestions(BuildContext context) => query.trim().length < 2 ? const SizedBox.shrink() : buildResults(context);

  @override
  Widget buildResults(BuildContext context) {
    final q = query.trim();
    if (q.isEmpty) return const SizedBox.shrink();
    if (q != _lastQuery) {
      _lastQuery = q;
      _future = session.call<List<PdfSearchHit>>('search', [q]);
    }
    return FutureBuilder<List<PdfSearchHit>>(
      future: _future,
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final hits = snap.data!;
        if (hits.isEmpty) {
          return const Padding(padding: EdgeInsets.all(24), child: Text('No matches. Scanned pages can only be searched after OCR.'));
        }
        return ListView.builder(
          itemCount: hits.length + 1,
          itemBuilder: (ctx, i) => i == 0
              ? Padding(padding: const EdgeInsets.all(12), child: Text('${hits.length}${hits.length >= 500 ? '+' : ''} matches'))
              : ListTile(
                  leading: Text('p. ${hits[i - 1].page + 1}'),
                  title: Text(hits[i - 1].context, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => close(context, hits[i - 1]),
                ),
        );
      },
    );
  }
}
