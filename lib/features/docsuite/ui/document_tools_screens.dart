import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/storage.dart' show friendlyError;
import '../../../shared/widgets.dart';
import '../../pdf/export_actions.dart';
import '../../pdf_editor/editor/signature_screen.dart';
import '../../pdf_editor/engine/pdfium_engine.dart' show PdfAnnotInfo;
import '../../pdf_editor/pdf_editor_launcher.dart';
import '../services/pdf_document_services.dart';
import 'area_picker.dart';
import 'working_doc.dart';

// Document services run in background isolates through top-level
// functions, so only the explicit arguments are sent.
FormSummary _readForm((Uint8List, String?) a) => const PdfFormService().read(a.$1, password: a.$2);
Uint8List _fillForm((Uint8List, Map<String, String>, String?, Map<String, Uint8List>, bool) a) =>
    const PdfFormService().fill(a.$1, a.$2, password: a.$3, signatureImages: a.$4, flatten: a.$5);
Uint8List _createField((Uint8List, NewFormField, String?) a) => const PdfFormService().create(a.$1, [a.$2], password: a.$3);
List<LinkInfo> _listLinks((Uint8List, String?) a) => const PdfLinkService().list(a.$1, password: a.$2);
Uint8List _addLink((Uint8List, int, Rect, LinkKind, String, String?) a) => const PdfLinkService().add(a.$1, a.$2, a.$3, a.$4, a.$5, password: a.$6);
Uint8List _removeLink((Uint8List, LinkInfo, String?) a) => const PdfLinkService().remove(a.$1, a.$2, password: a.$3);
Uint8List _editLink((Uint8List, LinkInfo, LinkKind, String, String?) a) => const PdfLinkService().edit(a.$1, a.$2, a.$3, a.$4, password: a.$5);
Uint8List _exportAnnots((Uint8List, AnnotationFormat, String?, String) a) => const PdfAnnotationService().export(a.$1, a.$2, password: a.$3, fileName: a.$4);
Uint8List _importAnnots((Uint8List, Uint8List, AnnotationFormat, String?) a) => const PdfAnnotationService().import(a.$1, a.$2, a.$3, password: a.$4);
Uint8List _flattenAnnots((Uint8List, String?, bool) a) => const PdfAnnotationService().flatten(a.$1, password: a.$2, forms: a.$3);
List<OutlineEntry> _listOutline((Uint8List, String?) a) => const PdfOutlineService().list(a.$1, password: a.$2);
Uint8List _addOutline((Uint8List, String, int, List<int>?, String?) a) => const PdfOutlineService().add(a.$1, a.$2, a.$3, parentPath: a.$4, password: a.$5);
Uint8List _removeOutline((Uint8List, List<int>, String?) a) => const PdfOutlineService().remove(a.$1, a.$2, password: a.$3);

/// Shared scaffold for tools working on a [WorkingDoc].
abstract class _DocToolState<T extends StatefulWidget> extends State<T> {
  late final WorkingDoc doc;
  Object? loadError;
  bool get ready => doc.cache != null;

  WorkingDoc createDoc();
  Future<void> afterLoad() async {}

  @override
  void initState() {
    super.initState();
    doc = createDoc()..addListener(_changed);
    doc.load().then((_) => afterLoad()).catchError((Object e) {
      if (mounted) setState(() => loadError = e);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    doc.removeListener(_changed);
    doc.dispose();
    super.dispose();
  }

  /// Applies a change computed in the background, with progress and errors.
  Future<bool> change(String message, Future<Uint8List> Function(Uint8List bytes, String? password) f) async {
    final bytes = doc.bytes, pw = doc.password;
    final out = await runBusy(context, message, (_) => f(bytes, pw));
    if (out == null) return false;
    await doc.apply(out);
    return true;
  }

  Widget loading() => loadError != null
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('This PDF could not be opened: ${friendlyError(loadError!)}')))
      : const Center(child: CircularProgressIndicator());
}

// ---------------------------------------------------------------------------
// Fill forms
// ---------------------------------------------------------------------------

class FormFillScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const FormFillScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends _DocToolState<FormFillScreen> {
  FormSummary? _form;
  final _values = <String, String>{};
  final _signatures = <String, Uint8List>{};
  final _controllers = <String, TextEditingController>{};

  @override
  WorkingDoc createDoc() => WorkingDoc(widget.bytes, widget.title, password: widget.password);

  @override
  Future<void> afterLoad() async {
    final b = doc.bytes, pw = doc.password;
    final f = await compute(_readForm, (b, pw));
    if (!mounted) return;
    setState(() {
      _form = f;
      for (final x in f.fields) {
        _values[x.name] = x.value;
        if (x.kind == FormFieldKind.text) _controllers[x.name] = TextEditingController(text: x.value);
      }
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sign(FormFieldInfo f) async {
    final r = await Navigator.of(context).push<SignatureChoice>(MaterialPageRoute(builder: (_) => const SignatureScreen()));
    if (r != null) setState(() => _signatures[f.name] = r.png);
  }

  Future<void> _save({required bool flatten}) async {
    for (final e in _controllers.entries) {
      _values[e.key] = e.value.text;
    }
    final b = doc.bytes, pw = doc.password;
    final values = Map<String, String>.of(_values), sigs = Map<String, Uint8List>.of(_signatures);
    final out = await runBusy(context, flatten ? 'Filling and flattening…' : 'Filling…',
        (_) => compute(_fillForm, (b, values, pw, sigs, flatten)));
    if (out == null || !mounted) return;
    await showResult(context, out, '${widget.title} (${flatten ? 'filled, flattened' : 'filled'})', password: pw, parentId: widget.parentId);
  }

  @override
  Widget build(BuildContext context) {
    final f = _form;
    return Scaffold(
      appBar: AppBar(title: const Text('Fill form')),
      body: f == null
          ? loading()
          : f.fields.isEmpty
              ? ListView(padding: const EdgeInsets.all(24), children: [
                  Text(f.hasXfa ? 'This PDF uses an XFA form, which cannot be filled here.' : 'This PDF has no fillable fields.',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  const Text('You can still fill it by typing text and placing your signature on the page with the PDF editor, or add fillable fields first.'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => PdfEditorLauncher.open(context, widget.bytes, widget.title, password: widget.password),
                    icon: const Icon(Icons.edit_document),
                    label: const Text('Type on the page (PDF editor)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                        builder: (_) => FormBuilderScreen(bytes: widget.bytes, title: widget.title, password: widget.password, parentId: widget.parentId))),
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('Create fillable fields'),
                  ),
                ])
              : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                  if (f.hasXfa)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.warning_amber),
                        title: Text('This PDF also contains an XFA form'),
                        subtitle: Text('Only its standard (AcroForm) fields are filled. Dynamic XFA forms are not supported.'),
                      ),
                    ),
                  for (final x in f.fields) _field(x),
                ]),
      bottomNavigationBar: f == null || f.fields.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  Expanded(child: OutlinedButton(onPressed: () => _save(flatten: true), child: const Text('Save flattened'))),
                  const SizedBox(width: 12),
                  Expanded(child: FilledButton(onPressed: () => _save(flatten: false), child: const Text('Save filled'))),
                ]),
              ),
            ),
    );
  }

  Widget _field(FormFieldInfo x) {
    final label = '${x.name}  ·  page ${x.page + 1}${x.readOnly ? '  ·  read-only' : ''}';
    switch (x.kind) {
      case FormFieldKind.text:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(controller: _controllers[x.name], enabled: !x.readOnly, decoration: InputDecoration(labelText: label), maxLines: null),
        );
      case FormFieldKind.checkbox:
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: _values[x.name] == 'true',
          onChanged: x.readOnly ? null : (v) => setState(() => _values[x.name] = '${v ?? false}'),
        );
      case FormFieldKind.radio || FormFieldKind.combo || FormFieldKind.list:
        final opts = x.options.toSet().toList();
        final current = opts.contains(_values[x.name]) ? _values[x.name] : null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButtonFormField<String>(
            initialValue: current,
            decoration: InputDecoration(labelText: label),
            items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: x.readOnly ? null : (v) => setState(() => _values[x.name] = v ?? ''),
          ),
        );
      case FormFieldKind.signature:
        final sig = _signatures[x.name];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.draw_outlined),
          title: Text(label),
          subtitle: Text(sig == null ? 'Signature area — adds an image of your signature (not a digital certificate signature)' : 'Signature added'),
          trailing: sig == null ? TextButton(onPressed: () => _sign(x), child: const Text('Sign')) : Image.memory(sig, height: 36),
          onTap: () => _sign(x),
        );
      default:
        return ListTile(contentPadding: EdgeInsets.zero, title: Text(label), subtitle: const Text('This field type cannot be filled here.'));
    }
  }
}

// ---------------------------------------------------------------------------
// Create fillable fields
// ---------------------------------------------------------------------------

class FormBuilderScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const FormBuilderScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<FormBuilderScreen> createState() => _FormBuilderScreenState();
}

class _FormBuilderScreenState extends _DocToolState<FormBuilderScreen> {
  var _page = 0;
  var _kind = FormFieldKind.text;
  List<FormFieldInfo> _existing = const [];

  @override
  WorkingDoc createDoc() => WorkingDoc(widget.bytes, widget.title, password: widget.password);

  @override
  Future<void> afterLoad() => _refresh();

  Future<void> _refresh() async {
    final b = doc.bytes, pw = doc.password;
    final f = await compute(_readForm, (b, pw));
    if (mounted) setState(() => _existing = f.fields);
  }

  Future<void> _drawn(Rect r) async {
    final nameC = TextEditingController(text: '${_kind.name}_${_existing.length + 1}');
    final labelC = TextEditingController();
    final optsC = TextEditingController(text: 'Option 1, Option 2');
    final maxC = TextEditingController();
    var multiline = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('New ${_kindLabel(_kind).toLowerCase()} field'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Field name')),
              TextField(controller: labelC, decoration: const InputDecoration(labelText: 'Label printed above (optional)')),
              if (_kind == FormFieldKind.combo || _kind == FormFieldKind.radio)
                TextField(controller: optsC, decoration: const InputDecoration(labelText: 'Choices, separated by commas')),
              if (_kind == FormFieldKind.text) ...[
                TextField(controller: maxC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Maximum length (optional)')),
                CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Multi-line'), value: multiline, onChanged: (v) => set(() => multiline = v ?? false)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final opts = optsC.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if ((_kind == FormFieldKind.combo || _kind == FormFieldKind.radio) && opts.isEmpty) {
      if (mounted) showSnack(context, 'Enter at least one choice.');
      return;
    }
    final rect = _kind == FormFieldKind.checkbox || _kind == FormFieldKind.radio ? Rect.fromLTWH(r.left, r.top, 14, 14) : r;
    final nf = NewFormField(_kind, nameC.text, _page, rect,
        label: labelC.text.trim(), options: opts, maxLength: int.tryParse(maxC.text) ?? 0, multiline: multiline, value: _kind == FormFieldKind.combo ? opts.first : '');
    if (!mounted) return;
    if (await change('Adding field…', (b, pw) => compute(_createField, (b, nf, pw)))) await _refresh();
  }

  static String _kindLabel(FormFieldKind k) => switch (k) {
        FormFieldKind.text => 'Text',
        FormFieldKind.checkbox => 'Checkbox',
        FormFieldKind.radio => 'Choice buttons',
        FormFieldKind.combo => 'Dropdown',
        FormFieldKind.signature => 'Signature',
        _ => k.name,
      };

  @override
  Widget build(BuildContext context) {
    final cache = doc.cache;
    return Scaffold(
      appBar: AppBar(title: const Text('Create form'), actions: workingDocActions(context, doc, doneLabel: 'form', parentId: widget.parentId)),
      body: cache == null
          ? loading()
          : Column(children: [
              SizedBox(
                height: 52,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), children: [
                  for (final k in const [FormFieldKind.text, FormFieldKind.checkbox, FormFieldKind.radio, FormFieldKind.combo, FormFieldKind.signature])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text(_kindLabel(k)), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
                    ),
                ]),
              ),
              const Text('Drag on the page to place the field', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: PageAreaPicker(
                    key: ValueKey(doc.generation),
                    cache: cache,
                    page: _page,
                    areas: [for (final f in _existing) PageArea(f.page, f.bounds, label: f.name, color: const Color(0x4400897B))],
                    onDrawn: _drawn,
                  ),
                ),
              ),
              PageStepper(page: _page, count: cache.pageCount, onChanged: (p) => setState(() => _page = p)),
            ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

class LinksScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const LinksScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends _DocToolState<LinksScreen> {
  var _page = 0;
  List<LinkInfo> _links = const [];

  @override
  WorkingDoc createDoc() => WorkingDoc(widget.bytes, widget.title, password: widget.password);

  @override
  Future<void> afterLoad() => _refresh();

  Future<void> _refresh() async {
    final b = doc.bytes, pw = doc.password;
    final l = await compute(_listLinks, (b, pw));
    if (mounted) setState(() => _links = l);
  }

  Future<(LinkKind, String)?> _ask({LinkKind kind = LinkKind.web, String target = ''}) {
    final c = TextEditingController(text: target);
    var k = kind;
    return showDialog<(LinkKind, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Link'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<LinkKind>(
              segments: const [
                ButtonSegment(value: LinkKind.web, label: Text('Web')),
                ButtonSegment(value: LinkKind.email, label: Text('E-mail')),
                ButtonSegment(value: LinkKind.page, label: Text('Page')),
              ],
              selected: {k},
              onSelectionChanged: (s) => set(() => k = s.first),
            ),
            TextField(
              controller: c,
              keyboardType: k == LinkKind.page ? TextInputType.number : (k == LinkKind.email ? TextInputType.emailAddress : TextInputType.url),
              decoration: InputDecoration(labelText: switch (k) { LinkKind.web => 'Web address', LinkKind.email => 'E-mail address', LinkKind.page => 'Page number' }),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, (k, c.text.trim())), child: const Text('OK')),
          ],
        ),
      ),
    );
  }

  Future<void> _drawn(Rect r) async {
    final v = await _ask();
    if (v == null || !mounted) return;
    final page = _page;
    if (await change('Adding link…', (b, pw) => compute(_addLink, (b, page, r, v.$1, v.$2, pw)))) await _refresh();
  }

  Future<void> _edit(LinkInfo l) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(l.target, maxLines: 2), subtitle: Text('Page ${l.page + 1}')),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Change target'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove link'), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    if (a == 'remove') {
      if (await change('Removing link…', (b, pw) => compute(_removeLink, (b, l, pw)))) await _refresh();
    } else {
      final v = await _ask(kind: l.kind, target: l.target.replaceFirst('mailto:', ''));
      if (v == null || !mounted) return;
      if (await change('Updating link…', (b, pw) => compute(_editLink, (b, l, v.$1, v.$2, pw)))) await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cache = doc.cache;
    final onPage = _links.where((l) => l.page == _page).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Links'), actions: workingDocActions(context, doc, doneLabel: 'links', parentId: widget.parentId)),
      body: cache == null
          ? loading()
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('${_links.length} link(s) in the document. Drag on the page to add a link; tap a link to edit or remove it.', style: const TextStyle(fontSize: 12)),
              ),
              Expanded(
                child: PageAreaPicker(
                  key: ValueKey(doc.generation),
                  cache: cache,
                  page: _page,
                  areas: [
                    for (final l in _links)
                      PageArea(l.page, l.bounds, label: l.kind == LinkKind.page ? '→ p. ${l.target}' : l.target, color: const Color(0x442196F3)),
                  ],
                  onDrawn: _drawn,
                  onTapArea: (a) => _edit(onPage.firstWhere((l) => l.bounds == a.rect)),
                ),
              ),
              PageStepper(page: _page, count: cache.pageCount, onChanged: (p) => setState(() => _page = p)),
            ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Annotations: summary, export/import, flatten
// ---------------------------------------------------------------------------

class AnnotationsScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const AnnotationsScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<AnnotationsScreen> createState() => _AnnotationsScreenState();
}

class _AnnotationsScreenState extends _DocToolState<AnnotationsScreen> {
  List<PdfAnnotInfo>? _annots;

  @override
  WorkingDoc createDoc() => WorkingDoc(widget.bytes, widget.title, password: widget.password);

  @override
  Future<void> afterLoad() => _refresh();

  Future<void> _refresh() async {
    final l = await doc.session!.call<List<PdfAnnotInfo>>('annotations');
    if (mounted) setState(() => _annots = l.where((a) => !a.subtype.startsWith('Widget') && a.subtype != 'Popup').toList());
  }

  Future<void> _export(AnnotationFormat f) async {
    final b = doc.bytes, pw = doc.password, name = '${widget.title}.pdf';
    final data = await runBusy(context, 'Exporting…', (_) => compute(_exportAnnots, (b, f, pw, name)));
    if (data == null || !mounted) return;
    await ExportActions.shareBytes(data, '${widget.title} annotations.${f.name}', mime: f == AnnotationFormat.json ? 'application/json' : 'application/octet-stream');
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['xfdf', 'fdf', 'json']);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    final format = AnnotationFormat.values.firstWhere((f) => f.name == ext);
    final data = await File(path).readAsBytes();
    if (format == AnnotationFormat.json) {
      try {
        jsonDecode(utf8.decode(data));
      } catch (_) {
        if (mounted) showSnack(context, 'This is not a valid annotation file.');
        return;
      }
    }
    if (!mounted) return;
    if (await change('Importing annotations…', (b, pw) => compute(_importAnnots, (b, data, format, pw)))) await _refresh();
  }

  Future<void> _flatten() async {
    var forms = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Flatten a copy?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Comments, highlights, stamps and drawings become part of the page and can no longer be edited or removed. The original stays unchanged. Links keep working.'),
            CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Also flatten form fields'), value: forms, onChanged: (v) => set(() => forms = v ?? false)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Flatten')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final b = doc.bytes, pw = doc.password, f = forms;
    final out = await runBusy(context, 'Flattening…', (_) => compute(_flattenAnnots, (b, pw, f)));
    if (out == null || !mounted) return;
    await showResult(context, out, '${widget.title} (flattened)', password: pw, parentId: widget.parentId);
  }

  @override
  Widget build(BuildContext context) {
    final a = _annots;
    final byType = <String, int>{};
    for (final x in a ?? const <PdfAnnotInfo>[]) {
      byType[x.subtype] = (byType[x.subtype] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Annotations'), actions: workingDocActions(context, doc, doneLabel: 'annotations', parentId: widget.parentId)),
      body: a == null
          ? loading()
          : ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.isEmpty ? 'No annotations' : '${a.length} annotation(s)', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [for (final e in byType.entries) Chip(label: Text('${_typeLabel(e.key)}: ${e.value}'))]),
                  ]),
                ),
              ),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: a.isEmpty ? null : () => _export(AnnotationFormat.xfdf), icon: const Icon(Icons.upload_file), label: const Text('Export XFDF')),
                OutlinedButton.icon(onPressed: a.isEmpty ? null : () => _export(AnnotationFormat.json), icon: const Icon(Icons.data_object), label: const Text('Export JSON')),
                OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.download), label: const Text('Import')),
                FilledButton.tonalIcon(onPressed: a.isEmpty ? null : _flatten, icon: const Icon(Icons.layers_clear_outlined), label: const Text('Flatten copy')),
              ]),
              const SizedBox(height: 12),
              for (final x in a)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: Text(x.contents.isEmpty ? _typeLabel(x.subtype) : x.contents, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(['Page ${x.page + 1}', _typeLabel(x.subtype), if (x.author.isNotEmpty) x.author].join(' · ')),
                ),
              const SizedBox(height: 8),
              Text('To add or edit annotations, use Edit PDF.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
    );
  }

  static String _typeLabel(String t) => switch (t) {
        'Text' => 'Note',
        'FreeText' => 'Text box',
        'Highlight' => 'Highlight',
        'Underline' => 'Underline',
        'StrikeOut' => 'Strikethrough',
        'Square' => 'Rectangle',
        'Circle' => 'Ellipse',
        'Ink' => 'Drawing',
        'Stamp' => 'Stamp',
        'Link' => 'Link',
        _ => t,
      };
}

// ---------------------------------------------------------------------------
// Bookmarks (outline)
// ---------------------------------------------------------------------------

class BookmarksScreen extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final String? password;
  final String? parentId;
  const BookmarksScreen({super.key, required this.bytes, required this.title, this.password, this.parentId});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends _DocToolState<BookmarksScreen> {
  List<OutlineEntry>? _entries;

  @override
  WorkingDoc createDoc() => WorkingDoc(widget.bytes, widget.title, password: widget.password);

  @override
  Future<void> afterLoad() => _refresh();

  Future<void> _refresh() async {
    final b = doc.bytes, pw = doc.password;
    final l = await compute(_listOutline, (b, pw));
    if (mounted) setState(() => _entries = l);
  }

  Future<void> _add({OutlineEntry? parent}) async {
    final t = TextEditingController();
    final pg = TextEditingController(text: '${(parent?.page ?? 0) + 1}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parent == null ? 'Add bookmark' : 'Add under "${parent.title}"'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: t, autofocus: true, decoration: const InputDecoration(labelText: 'Title')),
          TextField(controller: pg, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Page (1 – ${doc.pageCount})')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final title = t.text, page = (int.tryParse(pg.text) ?? 0) - 1, path = parent?.path;
    if (await change('Adding bookmark…', (b, pw) => compute(_addOutline, (b, title, page, path, pw)))) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final e = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks'), actions: workingDocActions(context, doc, doneLabel: 'bookmarks', parentId: widget.parentId)),
      floatingActionButton: e == null ? null : FloatingActionButton.extended(onPressed: () => _add(), icon: const Icon(Icons.bookmark_add_outlined), label: const Text('Add')),
      body: e == null
          ? loading()
          : e.isEmpty
              ? const EmptyState(icon: Icons.bookmarks_outlined, title: 'No bookmarks', message: 'Bookmarks form the table of contents other PDF readers show.')
              : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                  for (final x in e)
                    ListTile(
                      contentPadding: EdgeInsets.only(left: 16.0 + 20 * x.level, right: 4),
                      title: Text(x.title),
                      subtitle: Text(x.page == null ? 'No page' : 'Page ${x.page! + 1}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'child') {
                            await _add(parent: x);
                          } else if (await change('Removing bookmark…', (b, pw) => compute(_removeOutline, (b, x.path, pw)))) {
                            await _refresh();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'child', child: Text('Add sub-bookmark')),
                          PopupMenuItem(value: 'remove', child: Text('Remove (with sub-bookmarks)')),
                        ],
                      ),
                    ),
                ]),
    );
  }
}
