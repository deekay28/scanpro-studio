import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../../core/ids.dart' show formatBytes;
import '../../../core/storage.dart' show friendlyError;
import '../../../shared/widgets.dart';
import '../../pdf/pdf_library.dart';
import '../../pdf/pdf_service.dart';
import '../../pdf_editor/engine/pdfium_engine.dart'
    show ImageOptimizeOptions, OptimizeResult, PagePattern, PatternPage, PdfSearchHit, RedactArea, RedactOptions, RedactResult;
import '../services/pdf_document_services.dart';
import '../suite.dart';
import 'area_picker.dart';
import 'page_cache.dart';
import 'working_doc.dart';

// ---------------------------------------------------------------------------
// True redaction
// ---------------------------------------------------------------------------

class RedactScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const RedactScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<RedactScreen> createState() => _RedactScreenState();
}

class _RedactScreenState extends State<RedactScreen> {
  late final WorkingDoc _doc = WorkingDoc(widget.bytes, widget.title, password: widget.password);
  final _areas = <PageArea>[];
  var _page = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _doc.addListener(_changed);
    _doc.load().catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _doc.removeListener(_changed);
    _doc.dispose();
    super.dispose();
  }

  static const _mark = Color(0x66E53935);

  Future<void> _findText() async {
    final q = await promptText(context, 'Find text to redact', hint: 'e.g. a name, account or phone number', ok: 'Find');
    if (q == null || q.trim().isEmpty || !mounted) return;
    final hits = await runBusy(context, 'Searching…', (_) => _doc.session!.call<List<PdfSearchHit>>('search', [q.trim()]));
    if (hits == null || !mounted) return;
    if (hits.isEmpty) return showSnack(context, 'Not found. Text in scanned pages cannot be searched; mark those areas by hand.');
    setState(() {
      for (final h in hits) {
        for (final r in h.rects) {
          _areas.add(PageArea(h.page, r.inflate(1), color: _mark));
        }
      }
      _page = hits.first.page;
    });
    showSnack(context, 'Marked ${hits.length} match(es) on ${hits.map((h) => h.page).toSet().length} page(s). Review them before applying.');
  }

  Future<void> _apply() async {
    if (_areas.isEmpty) return showSnack(context, 'Mark at least one area first.');
    final ok = await confirm(
      context,
      'Apply redaction?',
      'A new copy is created in which everything inside the marked areas — text, images, drawings and comments — is permanently removed and covered black. '
          'The original file is not changed. The redacted copy has no password; protect it again if needed.',
      ok: 'Redact',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final map = <int, List<RedactArea>>{};
    for (final a in _areas) {
      map.putIfAbsent(a.page, () => []).add(RedactArea(a.rect));
    }
    final r = await runBusy(context, 'Removing content and verifying…', (_) => _doc.session!.call<RedactResult>('redact', [map, const RedactOptions()]));
    if (r == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(r.verified ? Icons.verified_outlined : Icons.error_outline, color: r.verified ? Colors.green : Colors.red),
        title: Text(r.verified ? 'Redaction verified' : 'Redaction could not be verified'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('${r.charsRemoved} character(s), ${r.imagesRedacted} image(s), ${r.pathsRemoved} drawing(s) and ${r.annotationsRemoved} annotation(s) removed.'),
            if (r.rasterizedPages.isNotEmpty)
              Text('\nPages ${r.rasterizedPages.map((p) => p + 1).join(', ')} were converted to images to remove content safely; their text is no longer selectable.'),
            if (r.verified) const Text('\nThe removed text was searched for in the new file and was not found.'),
            if (!r.verified) Text('\nRemoved text was still found (${r.leaks.length}). Do not share this copy.', style: const TextStyle(color: Colors.red)),
            for (final line in r.report.take(12)) Text('• $line', style: const TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    if (!mounted || !r.verified) return;
    await showResult(context, r.bytes, '${widget.title} (redacted)', parentId: widget.parentId);
  }

  @override
  Widget build(BuildContext context) {
    final cache = _doc.cache;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Redact'),
        actions: [
          IconButton(tooltip: 'Find text', icon: const Icon(Icons.manage_search), onPressed: cache == null ? null : _findText),
          IconButton(tooltip: 'Clear marks', icon: const Icon(Icons.layers_clear), onPressed: _areas.isEmpty ? null : () => setState(_areas.clear)),
        ],
      ),
      body: _error != null
          ? Center(child: Text('This PDF could not be opened: ${friendlyError(_error!)}'))
          : cache == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Drag over content to mark it, or find text. Tap a mark to remove it. Content under the marks is deleted, not just covered.',
                        style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: PageAreaPicker(
                      cache: cache,
                      page: _page,
                      areas: _areas,
                      drawColor: _mark,
                      onDrawn: (r) => setState(() => _areas.add(PageArea(_page, r, color: _mark))),
                      onTapArea: (a) => setState(() => _areas.remove(a)),
                    ),
                  ),
                  PageStepper(page: _page, count: cache.pageCount, onChanged: (p) => setState(() => _page = p)),
                ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _areas.isEmpty ? null : _apply,
            icon: const Icon(Icons.format_color_fill),
            label: Text('Redact ${_areas.length} area(s)'),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Password protection with permissions
// ---------------------------------------------------------------------------

Uint8List _protect((Uint8List, String?, String, String, Set<PdfPermission>) a) =>
    const PdfSecurityService().protect(a.$1, currentPassword: a.$2, userPassword: a.$3, ownerPassword: a.$4, allow: a.$5);

Future<void> protectWithPermissions(BuildContext context, Uint8List bytes, String title, {String? password, String? parentId}) async {
  final user = TextEditingController(), owner = TextEditingController();
  final allow = <PdfPermission>{PdfPermission.print, PdfPermission.highQualityPrint, PdfPermission.accessibility, PdfPermission.fillForms};
  var restrict = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Protect PDF'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: user, obscureText: true, decoration: const InputDecoration(labelText: 'Password to open (AES-256)')),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restrict what others can do'),
              value: restrict,
              onChanged: (v) => set(() => restrict = v ?? false),
            ),
            if (restrict) ...[
              TextField(controller: owner, obscureText: true, decoration: const InputDecoration(labelText: 'Permissions password (different)')),
              for (final (perm, label) in const [
                (PdfPermission.print, 'Printing'),
                (PdfPermission.highQualityPrint, 'High-quality printing'),
                (PdfPermission.copy, 'Copying text and images'),
                (PdfPermission.edit, 'Editing'),
                (PdfPermission.annotate, 'Comments'),
                (PdfPermission.fillForms, 'Filling forms'),
                (PdfPermission.assemble, 'Inserting, rotating or deleting pages'),
                (PdfPermission.accessibility, 'Screen readers'),
              ])
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Allow ${label.toLowerCase()}'),
                  value: allow.contains(perm),
                  onChanged: (v) => set(() => v == true ? allow.add(perm) : allow.remove(perm)),
                ),
              const Text(
                'Restrictions are respected by standard PDF apps, but they cannot prevent screenshots, photos of the screen or software that ignores them.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Protect')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final u = user.text, o = restrict ? owner.text : '';
  if (u.length < 4 && !(restrict && o.length >= 4)) return showSnack(context, 'Use a password of at least 4 characters.');
  if (restrict && o.isNotEmpty && o == u) return showSnack(context, 'Use a different permissions password, or anyone who can open the file can change the restrictions.');
  final perms = restrict ? Set.of(allow) : PdfPermission.values.toSet();
  final out = await runBusy(context, 'Encrypting (AES-256)…', (_) => compute(_protect, (bytes, password, u, o.isEmpty ? u : o, perms)));
  if (out == null || !context.mounted) return;
  await showResult(context, out, '$title (protected)', password: u.isEmpty ? o : u, parentId: parentId);
}

// ---------------------------------------------------------------------------
// Compression profiles
// ---------------------------------------------------------------------------

class _Profile {
  final String id, label, hint;
  final ImageOptimizeOptions options;
  const _Profile(this.id, this.label, this.hint, this.options);
}

const _profiles = [
  _Profile('hq', 'High quality', 'Images up to 220 dpi, JPEG 85%', ImageOptimizeOptions(maxDpi: 220, quality: 85)),
  _Profile('balanced', 'Balanced', 'Images up to 150 dpi, JPEG 75%', ImageOptimizeOptions(maxDpi: 150, quality: 75)),
  _Profile('small', 'Small file', 'Images up to 110 dpi, JPEG 60%', ImageOptimizeOptions(maxDpi: 110, quality: 60)),
  _Profile('email', 'Email', 'Images up to 96 dpi, JPEG 55%', ImageOptimizeOptions(maxDpi: 96, quality: 55)),
  _Profile('messaging', 'Messaging', 'Images up to 72 dpi, JPEG 45%', ImageOptimizeOptions(maxDpi: 72, quality: 45)),
  _Profile('print', 'Print', 'Images up to 300 dpi, JPEG 90%', ImageOptimizeOptions(maxDpi: 300, quality: 90)),
];

/// Compression that keeps text, links, forms, annotations and bookmarks:
/// only images above the profile's resolution are resampled.
class CompressScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const CompressScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  final _results = <String, OptimizeResult>{};
  String? _busy;
  var _grayscale = false;

  Future<void> _run(_Profile pr) async {
    setState(() => _busy = pr.id);
    try {
      final suite = await DocSuite.get();
      final s = await suite.host.open(widget.bytes, password: widget.password);
      try {
        final o = ImageOptimizeOptions(maxDpi: pr.options.maxDpi, quality: pr.options.quality, grayscale: _grayscale);
        final r = await s.call<OptimizeResult>('optimize', [o]);
        if (mounted) setState(() => _results['${pr.id}$_grayscale'] = r);
      } finally {
        s.close();
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.bytes.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Compress PDF')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text('Current size: ${formatBytes(size)}', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Text, links, form fields, comments and bookmarks are kept. Only pictures are resampled, so this is not lossless for images; '
            'files without large pictures shrink little.'),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Convert pictures to grayscale'), value: _grayscale, onChanged: (v) => setState(() => _grayscale = v)),
        for (final pr in _profiles) _tile(pr, size),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.warning_amber),
          title: const Text('Need it even smaller?'),
          subtitle: const Text('The older "Compress PDF" tool in Tools can turn pages into images. That removes selectable text quality, vector sharpness, links and form fields.'),
        ),
      ]),
    );
  }

  Widget _tile(_Profile pr, int size) {
    final r = _results['${pr.id}$_grayscale'];
    final saved = r == null ? 0 : size - r.bytes.length;
    return Card(
      child: ListTile(
        title: Text(pr.label),
        subtitle: Text(r == null
            ? pr.hint
            : saved <= 0
                ? 'No reduction (${formatBytes(r.bytes.length)}): the pictures are already small. Keep the original.'
                : '${formatBytes(size)} → ${formatBytes(r.bytes.length)} (${(saved * 100 / size).round()}% smaller) · ${r.imagesRecompressed} picture(s) resampled'),
        trailing: _busy == pr.id
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : r == null
                ? TextButton(onPressed: _busy == null ? () => _run(pr) : null, child: const Text('Try'))
                : saved > 0
                    ? FilledButton(
                        onPressed: () => showResult(context, r.bytes, '${widget.title} (${pr.label.toLowerCase()})', password: widget.password, parentId: widget.parentId),
                        child: const Text('Use'),
                      )
                    : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page tools: lined/grid pages, replace pages, repair
// ---------------------------------------------------------------------------

class PageToolsScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const PageToolsScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<PageToolsScreen> createState() => _PageToolsScreenState();
}

class _PageToolsScreenState extends State<PageToolsScreen> {
  late final WorkingDoc _doc = WorkingDoc(widget.bytes, widget.title, password: widget.password);
  var _pattern = PagePattern.lined;
  var _count = 1;
  var _letter = false;
  final _at = TextEditingController();

  @override
  void initState() {
    super.initState();
    _doc.addListener(_changed);
    _doc.load().then((_) => _at.text = '${_doc.pageCount + 1}');
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _doc.removeListener(_changed);
    _doc.dispose();
    _at.dispose();
    super.dispose();
  }

  Future<void> _insert() async {
    final n = _doc.pageCount;
    final at = (int.tryParse(_at.text) ?? n + 1).clamp(1, n + 1) - 1;
    final size = _letter ? const Size(612, 792) : const Size(595.28, 841.89);
    final pages = [for (var i = 0; i < _count; i++) PatternPage(at + i, _pattern, size: size)];
    final out = await runBusy(context, 'Adding pages…', (_) => _doc.session!.call<Uint8List>('insertPages', [pages]));
    if (out != null) await _doc.apply(out);
  }

  Future<void> _replace() async {
    final picked = await PdfLibrary.pickAndOpen(context);
    if (picked.isEmpty || !mounted) return;
    final other = picked.first;
    final spec = await promptText(context, 'Replace pages',
        hint: 'this → other, e.g. 2=1, 3=2', initial: '1=1', ok: 'Replace');
    if (spec == null || !mounted) return;
    final map = <int, int>{};
    try {
      for (final part in spec.split(',')) {
        final kv = part.split(RegExp(r'=|→|->'));
        if (kv.length != 2) throw const FormatException('Use pairs like 2=1.');
        final a = int.parse(kv[0].trim()), b = int.parse(kv[1].trim());
        if (a < 1 || a > _doc.pageCount) throw FormatException('This document has ${_doc.pageCount} pages.');
        if (b < 1 || b > other.info.pageCount) throw FormatException('"${other.name}" has ${other.info.pageCount} pages.');
        map[a - 1] = b - 1;
      }
    } catch (e) {
      return showSnack(context, e is FormatException ? e.message : 'Use pairs like 2=1.');
    }
    final out = await runBusy(context, 'Replacing pages…', (_) => _doc.session!.call<Uint8List>('replacePages', [other.bytes, other.password, map]));
    if (out != null) await _doc.apply(out);
  }

  Future<void> _repair() async {
    final out = await runBusy(context, 'Repairing…', (_) async {
      final suite = await DocSuite.get();
      return suite.host.run<Uint8List>('repair', [_doc.bytes, _doc.password]);
    });
    if (out == null || !mounted) return;
    showSnack(context, 'The file was read and rewritten with a fresh structure (${formatBytes(_doc.bytes.length)} → ${formatBytes(out.length)}).');
    await _doc.apply(out);
  }

  @override
  Widget build(BuildContext context) {
    final cache = _doc.cache;
    return Scaffold(
      appBar: AppBar(title: const Text('Page tools'), actions: workingDocActions(context, _doc, doneLabel: 'pages', parentId: widget.parentId)),
      body: cache == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              Text('${cache.pageCount} page(s)', style: Theme.of(context).textTheme.titleMedium),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  key: ValueKey(_doc.generation),
                  scrollDirection: Axis.horizontal,
                  itemCount: cache.pageCount,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(children: [
                      Expanded(child: FittedBox(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.black26)), child: RenderedPageView(cache: cache, page: i, width: 70)))),
                      Text('${i + 1}', style: const TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Insert writing pages', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    SegmentedButton<PagePattern>(
                      segments: const [
                        ButtonSegment(value: PagePattern.blank, label: Text('Blank')),
                        ButtonSegment(value: PagePattern.lined, label: Text('Lined')),
                        ButtonSegment(value: PagePattern.grid, label: Text('Grid')),
                        ButtonSegment(value: PagePattern.dotted, label: Text('Dots')),
                      ],
                      selected: {_pattern},
                      onSelectionChanged: (s) => setState(() => _pattern = s.first),
                    ),
                    Row(children: [
                      const Text('Pages: '),
                      IconButton(onPressed: _count > 1 ? () => setState(() => _count--) : null, icon: const Icon(Icons.remove)),
                      Text('$_count'),
                      IconButton(onPressed: _count < 50 ? () => setState(() => _count++) : null, icon: const Icon(Icons.add)),
                      const Spacer(),
                      ChoiceChip(label: Text(_letter ? 'Letter' : 'A4'), selected: true, onSelected: (_) => setState(() => _letter = !_letter)),
                    ]),
                    TextField(controller: _at, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Insert before page (last + 1 = at the end)')),
                    const SizedBox(height: 8),
                    FilledButton.tonal(onPressed: _insert, child: const Text('Insert')),
                  ]),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.find_replace),
                  title: const Text('Replace pages'),
                  subtitle: const Text('Swap pages for pages from another PDF'),
                  onTap: _replace,
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.healing),
                  title: const Text('Repair'),
                  subtitle: const Text('Rewrites a damaged or oddly structured file. Content that cannot be read is not recovered.'),
                  onTap: _repair,
                ),
              ),
              const SizedBox(height: 8),
              Text('Merge, split, extract, reorder, rotate and delete pages are in Tools → Organise pages / Split.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Headers, footers, page numbers, watermarks
// ---------------------------------------------------------------------------

Uint8List _stamp((Uint8List, StampOptions, String?, Uint8List) a) => const PdfStampService().apply(a.$1, a.$2, password: a.$3, unicodeFont: a.$4);

class StampScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const StampScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<StampScreen> createState() => _StampScreenState();
}

class _StampScreenState extends State<StampScreen> {
  final _c = {
    for (final k in ['hl', 'hc', 'hr', 'fl', 'fc', 'fr', 'wm', 'range', 'title', 'first']) k: TextEditingController(),
  };
  var _size = 10.0, _margin = 24.0, _wmOpacity = 0.15, _imgOpacity = 0.15, _imgScale = 0.5;
  Uint8List? _image;
  int? _tint;
  Uint8List? _preview;
  var _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _c['fc']!.text = 'Page {page} of {pages}';
    _c['title']!.text = widget.title;
    _c['first']!.text = '1';
    try {
      _pageCount = PdfService.inspect(PdfSource(widget.bytes, password: widget.password)).pageCount;
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  StampOptions? _options() {
    List<int>? pages;
    final r = _c['range']!.text.trim();
    if (r.isNotEmpty) {
      try {
        pages = PdfService.parseRanges(r, _pageCount).expand((e) => e).toSet().toList();
      } catch (e) {
        showSnack(context, 'Pages: ${e is FormatException ? e.message : e}');
        return null;
      }
    }
    return StampOptions(
      header: {StampAlign.left: _c['hl']!.text, StampAlign.center: _c['hc']!.text, StampAlign.right: _c['hr']!.text},
      footer: {StampAlign.left: _c['fl']!.text, StampAlign.center: _c['fc']!.text, StampAlign.right: _c['fr']!.text},
      fontSize: _size,
      margin: _margin,
      pages: pages,
      firstNumber: int.tryParse(_c['first']!.text) ?? 1,
      title: _c['title']!.text,
      fileName: '${widget.title}.pdf',
      watermarkText: _c['wm']!.text,
      watermarkOpacity: _wmOpacity,
      watermarkImage: _image,
      imageOpacity: _imgOpacity,
      imageScale: _imgScale,
      backgroundTint: _tint,
    );
  }

  Future<Uint8List?> _render() async {
    final o = _options();
    if (o == null) return null;
    final suite = await DocSuite.get();
    if (!mounted) return null;
    final b = widget.bytes, pw = widget.password;
    return runBusy(context, 'Applying…', (_) => compute(_stamp, (b, o, pw, suite.unicodeFont)));
  }

  Future<void> _previewFirst() async {
    final out = await _render();
    if (out == null || !mounted) return;
    final suite = await DocSuite.get();
    final s = await suite.host.open(out, password: widget.password);
    try {
      final first = _options()?.pages?.firstOrNull ?? 0;
      final png = await s.call<Uint8List>('renderEncoded', [first, 72.0, 1, 90, false]);
      if (mounted) setState(() => _preview = png);
    } finally {
      s.close();
    }
  }

  Future<void> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg']);
    final path = r?.files.single.path;
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() => _image = bytes);
  }

  Widget _row(String label, String l, String c, String r) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          SizedBox(width: 56, child: Text(label)),
          for (final (k, hint) in [(l, 'Left'), (c, 'Centre'), (r, 'Right')])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: TextField(controller: _c[k], decoration: InputDecoration(hintText: hint, isDense: true)),
              ),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Headers, footers & watermark')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          const Text('Codes: {page} page number, {pages} total, {date} today, {title} title, {file} file name.', style: TextStyle(fontSize: 12)),
          _row('Header', 'hl', 'hc', 'hr'),
          _row('Footer', 'fl', 'fc', 'fr'),
          Row(children: [
            Expanded(child: TextField(controller: _c['title'], decoration: const InputDecoration(labelText: 'Title for {title}'))),
            const SizedBox(width: 8),
            SizedBox(width: 120, child: TextField(controller: _c['first'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'First number'))),
          ]),
          TextField(controller: _c['range'], decoration: InputDecoration(labelText: 'Pages (e.g. 2-$_pageCount) — empty for all')),
          LabeledSlider(label: 'Text size', value: _size, min: 6, max: 24, format: (v) => '${v.round()}', onChanged: (v) => setState(() => _size = v.roundToDouble())),
          LabeledSlider(label: 'Margin', value: _margin, min: 8, max: 72, format: (v) => '${v.round()}', onChanged: (v) => setState(() => _margin = v.roundToDouble())),
          const SizedBox(height: 8),
          TextField(controller: _c['wm'], decoration: const InputDecoration(labelText: 'Text watermark (e.g. CONFIDENTIAL)')),
          LabeledSlider(label: 'Opacity', value: _wmOpacity, min: 0.05, max: 0.6, onChanged: (v) => setState(() => _wmOpacity = v)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _image == null ? const Icon(Icons.image_outlined) : Image.memory(_image!, width: 40, height: 40),
            title: const Text('Image watermark'),
            subtitle: Text(_image == null ? 'Optional logo or stamp, centred' : 'Centred on each page'),
            trailing: _image == null
                ? TextButton(onPressed: _pickImage, child: const Text('Choose'))
                : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _image = null)),
          ),
          if (_image != null) ...[
            LabeledSlider(label: 'Image size', value: _imgScale, min: 0.1, max: 1, onChanged: (v) => setState(() => _imgScale = v)),
            LabeledSlider(label: 'Image opacity', value: _imgOpacity, min: 0.05, max: 1, onChanged: (v) => setState(() => _imgOpacity = v)),
          ],
          const SizedBox(height: 8),
          const Text('Background tint'),
          Wrap(spacing: 10, children: [
            for (final c in const [null, 0xFFFFF8E1, 0xFFE3F2FD, 0xFFE8F5E9, 0xFFFCE4EC])
              ChoiceChip(
                label: Text(c == null ? 'None' : '  '),
                selected: _tint == c,
                selectedColor: c == null ? null : Color(c),
                backgroundColor: c == null ? null : Color(c),
                onSelected: (_) => setState(() => _tint = c),
              ),
          ]),
          const Text('The tint is blended over the page so text stays readable; pictures are tinted too.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          if (_preview != null) Container(decoration: BoxDecoration(border: Border.all(color: Colors.black26)), child: Image.memory(_preview!)),
          const SizedBox(height: 80),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Expanded(child: OutlinedButton(onPressed: _previewFirst, child: const Text('Preview'))),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    final out = await _render();
                    if (out != null && context.mounted) await showResult(context, out, '${widget.title} (stamped)', password: widget.password, parentId: widget.parentId);
                  },
                  child: const Text('Apply to copy'),
                ),
              ),
            ]),
          ),
        ),
      );
}
