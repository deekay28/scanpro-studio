import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../shared/widgets.dart';
import '../../docsuite/suite.dart';
import '../../pdf/export_actions.dart';
import '../../pdf/pdf_service.dart';
import '../../pdf_editor/engine/pdfium_engine.dart' show RasterFormat;
import '../conversion_jobs.dart';
import '../conversion_service.dart';
import 'ocr_review_screen.dart';
import 'output_preview.dart';
import 'table_review_screen.dart';

IconData iconFor(ConversionType t) => switch (t.target) {
      'docx' => Icons.description_outlined,
      'xlsx' => Icons.table_chart_outlined,
      'pptx' => Icons.slideshow_outlined,
      'jpg' => Icons.image_outlined,
      'txt' => Icons.text_snippet_outlined,
      'html' => Icons.code,
      'csv' => Icons.grid_on,
      _ => Icons.picture_as_pdf_outlined,
    };

/// Entry point of all conversions: a grid of conversion types, grouped by
/// direction, with the job queue one tap away.
class ConversionCentreScreen extends StatelessWidget {
  const ConversionCentreScreen({super.key});

  static Future<void> open(BuildContext context, {ConversionType? type, List<(String, String)> files = const [], Map<String, String> passwords = const {}}) {
    final nav = Navigator.of(context);
    if (type != null) {
      return nav.push(MaterialPageRoute(builder: (_) => ConversionSetupScreen(type: type, initialFiles: files, knownPasswords: passwords)));
    }
    return nav.push(MaterialPageRoute(builder: (_) => const ConversionCentreScreen()));
  }

  /// Lets the user choose a conversion for an in-memory PDF (from the
  /// viewer or the library).
  static Future<void> convertPdf(BuildContext context, Uint8List bytes, String title, {String? password}) async {
    final type = await showModalBottomSheet<ConversionType>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Convert this PDF to…', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final t in ConversionType.values.where((t) => t.fromPdf))
            ListTile(leading: Icon(iconFor(t)), title: Text(t.label), onTap: () => Navigator.pop(ctx, t)),
        ]),
      ),
    );
    if (type == null) return;
    final path = await tempFileFor(bytes, '${_safe(title)}.pdf');
    if (!context.mounted) return;
    await open(context, type: type, files: [(path, '${_safe(title)}.pdf')], passwords: {if (password != null) '${_safe(title)}.pdf': password});
  }

  static String _safe(String s) {
    final c = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return c.isEmpty ? 'document' : c;
  }

  @override
  Widget build(BuildContext context) {
    final groups = <(String, List<ConversionType>)>[
      ('From PDF', ConversionType.values.where((t) => t.fromPdf).toList()),
      ('To PDF', ConversionType.values.where((t) => !t.fromPdf && t.target == 'pdf').toList()),
      ('Office', [ConversionType.pptxToXlsx, ConversionType.xlsxToPptx]),
    ];
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Convert'), actions: [const JobsButton()]),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Everything runs on this device. Files are never uploaded.', style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        ),
        for (final g in groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(g.$1, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisExtent: 92, crossAxisSpacing: 8, mainAxisSpacing: 8),
              delegate: SliverChildBuilderDelegate(
                childCount: g.$2.length,
                (ctx, i) {
                  final t = g.$2[i];
                  return Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => open(context, type: t),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(iconFor(t), color: cs.primary),
                          const SizedBox(height: 6),
                          Text(t.label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ]),
    );
  }
}

/// App-bar button that opens the job queue and shows how many jobs run.
class JobsButton extends StatelessWidget {
  const JobsButton({super.key});

  void _open(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConversionJobsScreen()));

  @override
  Widget build(BuildContext context) {
    // Only shows live counts once the suite is running; looking at the
    // conversion list does not start the PDF engine.
    final suite = DocSuite.started;
    if (suite == null) {
      return IconButton(tooltip: 'Conversion jobs', icon: const Icon(Icons.pending_actions_outlined), onPressed: () => _open(context));
    }
    return ListenableBuilder(
      listenable: suite.jobs,
      builder: (ctx, _) {
        final active = suite.jobs.jobs.where((j) => j.active).length;
        return IconButton(
          tooltip: 'Conversion jobs',
          icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.pending_actions_outlined)),
          onPressed: () => _open(context),
        );
      },
    );
  }
}

class _Source {
  final String path;
  final String name;
  final int size;
  bool encrypted = false;
  String? password;
  int? pages;
  _Source(this.path, this.name, this.size);
}

/// Choose files and options for one conversion type, then queue it.
class ConversionSetupScreen extends StatefulWidget {
  final ConversionType type;
  final List<(String, String)> initialFiles;
  final Map<String, String> knownPasswords; // file name → password already entered in the app
  const ConversionSetupScreen({super.key, required this.type, this.initialFiles = const [], this.knownPasswords = const {}});

  @override
  State<ConversionSetupScreen> createState() => _ConversionSetupScreenState();
}

class _ConversionSetupScreenState extends State<ConversionSetupScreen> {
  final _sources = <_Source>[];
  final _name = TextEditingController();
  final _range = TextEditingController();
  final _template = TextEditingController(text: '{name}_page{n}');
  var _o = const ConversionOptions();
  ConversionType get t => widget.type;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (final (path, name) in widget.initialFiles) {
        await _add(path, name);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _range.dispose();
    _template.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: t.sources, allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) {
      if (f.path != null) await _add(f.path!, f.name);
    }
  }

  Future<void> _add(String path, String name) async {
    final file = File(path);
    if (!await file.exists()) return;
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (!t.sources.contains(ext)) {
      if (mounted) showSnack(context, '$name is not a ${t.sources.first.toUpperCase()} file.');
      return;
    }
    if (_sources.any((s) => s.path == path)) return;
    final src = _Source(path, name, await file.length());
    if (src.size == 0) {
      if (mounted) showSnack(context, '$name is empty.');
      return;
    }
    if (ext == 'pdf') {
      final bytes = await file.readAsBytes();
      try {
        src.pages = PdfService.inspect(PdfSource(bytes)).pageCount;
      } on PdfPasswordRequired {
        src.encrypted = true;
        final known = widget.knownPasswords[name];
        try {
          if (known == null) throw PdfPasswordRequired();
          src.pages = PdfService.inspect(PdfSource(bytes, password: known)).pageCount;
          src.password = known;
        } on PdfPasswordRequired {
          if (!mounted) return;
          if (!await _askPassword(src, bytes)) return;
        }
      } catch (_) {
        if (mounted) showSnack(context, '$name could not be opened. It may be damaged.');
        return;
      }
    }
    setState(() {
      _sources.add(src);
      if (_name.text.isEmpty) _name.text = p.basenameWithoutExtension(name);
    });
  }

  Future<bool> _askPassword(_Source src, Uint8List bytes) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final pw = await promptText(context, attempt == 0 ? '"${src.name}" is password protected' : 'Incorrect password, try again',
          hint: 'PDF password', obscure: true, ok: 'Unlock');
      if (pw == null) return false;
      try {
        src.pages = PdfService.inspect(PdfSource(bytes, password: pw)).pageCount;
        src.password = pw;
        return true;
      } on PdfPasswordRequired {
        continue;
      }
    }
    return false;
  }

  ConversionOptions get _options => ConversionOptions(
        pageRange: _range.text.trim(),
        ocr: _o.ocr,
        ocrScript: _o.ocrScript,
        docxMode: _o.docxMode,
        pageDpi: _o.pageDpi,
        markUncertain: _o.markUncertain,
        pptxEditable: _o.pptxEditable,
        sheetPerPage: _o.sheetPerPage,
        allTextIfNoTable: _o.allTextIfNoTable,
        imageFormat: _o.imageFormat,
        dpi: _o.dpi,
        jpegQuality: _o.jpegQuality,
        grayscale: _o.grayscale,
        zip: _o.zip,
        fileNameTemplate: _template.text.trim().isEmpty ? '{name}_page{n}' : _template.text.trim(),
        cellRange: t == ConversionType.xlsxToPdf || t == ConversionType.xlsxToPptx ? _range.text.trim() : '',
        slideRange: t == ConversionType.pptxToPdf || t == ConversionType.pptxToXlsx ? _range.text.trim() : '',
        charts: _o.charts,
        fitToA4: _o.fitToA4,
        extractTables: _o.extractTables,
        extractCharts: _o.extractCharts,
        extractText: _o.extractText,
        slideSheets: _o.slideSheets,
      );

  ConversionOptions _with({
    bool? ocr,
    String? ocrScript,
    DocxMode? docxMode,
    double? pageDpi,
    bool? markUncertain,
    bool? pptxEditable,
    bool? sheetPerPage,
    bool? allTextIfNoTable,
    RasterFormat? imageFormat,
    double? dpi,
    int? jpegQuality,
    bool? grayscale,
    bool? zip,
    bool? charts,
    bool? fitToA4,
    bool? extractTables,
    bool? extractCharts,
    bool? extractText,
    bool? slideSheets,
  }) =>
      ConversionOptions(
        ocr: ocr ?? _o.ocr,
        ocrScript: ocrScript ?? _o.ocrScript,
        docxMode: docxMode ?? _o.docxMode,
        pageDpi: pageDpi ?? _o.pageDpi,
        markUncertain: markUncertain ?? _o.markUncertain,
        pptxEditable: pptxEditable ?? _o.pptxEditable,
        sheetPerPage: sheetPerPage ?? _o.sheetPerPage,
        allTextIfNoTable: allTextIfNoTable ?? _o.allTextIfNoTable,
        imageFormat: imageFormat ?? _o.imageFormat,
        dpi: dpi ?? _o.dpi,
        jpegQuality: jpegQuality ?? _o.jpegQuality,
        grayscale: grayscale ?? _o.grayscale,
        zip: zip ?? _o.zip,
        charts: charts ?? _o.charts,
        fitToA4: fitToA4 ?? _o.fitToA4,
        extractTables: extractTables ?? _o.extractTables,
        extractCharts: extractCharts ?? _o.extractCharts,
        extractText: extractText ?? _o.extractText,
        slideSheets: slideSheets ?? _o.slideSheets,
      );

  void _set(ConversionOptions o) => setState(() => _o = o);

  /// Rough output size for PDF → images (shown before converting).
  String? get _imageEstimate {
    if (t != ConversionType.pdfToImages || _sources.isEmpty) return null;
    var pages = 0;
    for (final s in _sources) {
      final n = s.pages ?? 0;
      pages += _range.text.trim().isEmpty ? n : _rangeCount(_range.text, n);
    }
    // A4 page at the chosen resolution.
    final px = (8.27 * _o.dpi) * (11.69 * _o.dpi);
    final perPage = switch (_o.imageFormat) {
      RasterFormat.jpg => px * (_o.grayscale ? 0.06 : 0.12) * (_o.jpegQuality / 85),
      RasterFormat.png => px * (_o.grayscale ? 0.25 : 0.6),
      RasterFormat.tiff => px * (_o.grayscale ? 0.5 : 1.5),
    };
    return '$pages image(s), about ${_fmtSize((perPage * pages).round())} (depends on the page content)';
  }

  int _rangeCount(String r, int n) {
    try {
      return PdfService.parseRanges(r, n).expand((e) => e).toSet().length;
    } catch (_) {
      return 0;
    }
  }

  String? _validate() {
    if (_sources.isEmpty) return 'Add at least one file.';
    if (_name.text.trim().isEmpty) return 'Enter an output name.';
    final r = _range.text.trim();
    if (r.isNotEmpty && t.fromPdf) {
      for (final s in _sources) {
        try {
          PdfService.parseRanges(r, s.pages ?? 1);
        } catch (e) {
          return 'Page range: ${e is FormatException ? e.message : e}';
        }
      }
    }
    return null;
  }

  Future<void> _convert() async {
    final err = _validate();
    if (err != null) return showSnack(context, err);
    final suite = await DocSuite.get();
    try {
      await suite.jobs.enqueue(
        t,
        [for (final s in _sources) (s.path, s.name)],
        _options,
        _name.text.trim(),
        passwords: {for (final s in _sources) if (s.password != null) s.name: s.password!},
        encrypted: {for (final s in _sources) if (s.encrypted) s.name},
      );
    } catch (e) {
      if (mounted) showSnack(context, describeError(e));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ConversionJobsScreen()));
  }

  Future<void> _review() async {
    final err = _validate();
    if (err != null) return showSnack(context, err);
    final s = _sources.first;
    final suite = await DocSuite.get();
    if (!mounted) return;
    final token = CancelToken();
    final r = await runBusy(context, 'Finding tables…', cancellable: true, (ctl) async {
      final poll = Stream.periodic(const Duration(milliseconds: 200)).listen((_) => token.cancelled = ctl.cancelled);
      try {
        return await suite.conversions.previewSheets(t, s.path, s.password, _options, onProgress: (v, m) => ctl.update(m, v), cancel: token);
      } finally {
        await poll.cancel();
      }
    });
    if (r == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableReviewScreen(sheets: r.$1, warnings: r.$2, baseName: _name.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    final multi = t != ConversionType.imagesToPdf;
    final tableType = t == ConversionType.pdfToXlsx || t == ConversionType.pdfToCsv || t == ConversionType.pptxToXlsx;
    final estimate = _imageEstimate;
    return Scaffold(
      appBar: AppBar(title: Text(t.label), actions: const [JobsButton()]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        _Header(t == ConversionType.imagesToPdf ? 'Images (in page order)' : (multi ? 'Files (each becomes its own output)' : 'File')),
        if (_sources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No files selected. Supported: ${t.sources.map((e) => '.$e').join(', ')}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: t == ConversionType.imagesToPdf,
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            _sources.insert(b, _sources.removeAt(a));
          }),
          children: [
            for (final s in _sources)
              ListTile(
                key: ValueKey(s.path),
                contentPadding: EdgeInsets.zero,
                leading: Icon(s.encrypted ? Icons.lock_outline : Icons.insert_drive_file_outlined),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([_fmtSize(s.size), if (s.pages != null) '${s.pages} page(s)', if (s.encrypted) 'unlocked for this job'].join(' · ')),
                trailing: IconButton(icon: const Icon(Icons.close), tooltip: 'Remove', onPressed: () => setState(() => _sources.remove(s))),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.add), label: Text(_sources.isEmpty ? 'Choose files' : 'Add files')),
        ),
        const _Header('Output'),
        TextField(
          controller: _name,
          decoration: InputDecoration(
            labelText: 'Output name',
            helperText: _sources.length > 1 && multi ? 'With several files, each output is named after its source file.' : null,
            suffixText: '.${t.target == 'jpg' ? (_o.zip ? 'zip' : _o.imageFormat.name) : t.target}',
          ),
        ),
        const SizedBox(height: 12),
        if (t.fromPdf || t == ConversionType.pptxToPdf || t == ConversionType.pptxToXlsx || t == ConversionType.xlsxToPdf || t == ConversionType.xlsxToPptx)
          TextField(
            controller: _range,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: switch (t) {
                ConversionType.pptxToPdf || ConversionType.pptxToXlsx => 'Slides (e.g. 1-3, 5) — empty for all',
                ConversionType.xlsxToPdf || ConversionType.xlsxToPptx => 'Cell range (e.g. A1:F30) — empty for used cells',
                _ => 'Pages (e.g. 1-3, 5) — empty for all',
              },
            ),
          ),
        ..._optionWidgets(),
        if (estimate != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Estimated output: $estimate')),
        const SizedBox(height: 8),
        _InfoNote(text: _limitNote(t)),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            if (tableType && _sources.length == 1) ...[
              Expanded(child: OutlinedButton.icon(onPressed: _review, icon: const Icon(Icons.table_view), label: const Text('Review tables'))),
              const SizedBox(width: 12),
            ],
            Expanded(child: FilledButton.icon(onPressed: _sources.isEmpty ? null : _convert, icon: const Icon(Icons.play_arrow), label: const Text('Convert'))),
          ]),
        ),
      ),
    );
  }

  List<Widget> _optionWidgets() {
    final o = _o;
    final ocrOpts = [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('OCR for scanned pages'),
        subtitle: const Text('Recognises text on image-only pages (on this device)'),
        value: o.ocr,
        onChanged: (v) => _set(_with(ocr: v)),
      ),
      if (o.ocr)
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
          const Text('OCR language:'),
          DropdownButton<String>(
            value: o.ocrScript,
            items: const [DropdownMenuItem(value: 'latin', child: Text('English / Latin')), DropdownMenuItem(value: 'devanagari', child: Text('Hindi / Devanagari'))],
            onChanged: (v) => _set(_with(ocrScript: v)),
          ),
        ]),
    ];
    switch (t) {
      case ConversionType.pdfToDocx:
        return [
          const _Header('Word layout'),
          for (final (mode, title, text) in const [
            (DocxMode.automatic, 'Automatic', 'Scanned pages are kept as page images; digital pages become editable text. The result lists what was chosen for each page.'),
            (DocxMode.faithful, 'Faithful layout', 'Every page looks exactly like the original (one page-sized picture per page). The text is a picture and cannot be edited.'),
            (DocxMode.editable, 'Editable document', 'Real Word text, tables and pictures at their original positions. Scans are read with OCR; seals, signatures and QR codes stay pictures. Some visual differences remain.'),
          ])
            RadioListTile<DocxMode>(
              contentPadding: EdgeInsets.zero,
              value: mode,
              groupValue: o.docxMode,
              onChanged: (v) => _set(_with(docxMode: v)),
              title: Text(title),
              subtitle: Text(text),
            ),
          if (o.docxMode != DocxMode.faithful) ...[
            ...ocrOpts,
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Highlight uncertain words (review copy)'),
              subtitle: const Text('Off: a clean document; uncertain words are listed in "Review OCR words" instead'),
              value: o.markUncertain,
              onChanged: (v) => _set(_with(markUncertain: v)),
            ),
          ],
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Advanced: page image quality'),
            children: [
              const Text('Used for pages kept as images. A scanned photo is copied unchanged whenever possible; other pages are rendered at this resolution.',
                  style: TextStyle(fontSize: 12)),
              LabeledSlider(
                label: 'Resolution',
                value: o.pageDpi,
                min: 150,
                max: 400,
                format: (v) => '${v.round()} dpi',
                onChanged: (v) => _set(_with(pageDpi: (v / 50).round() * 50.0)),
              ),
              LabeledSlider(
                label: 'JPEG quality',
                value: o.jpegQuality.toDouble().clamp(60, 100),
                min: 60,
                max: 100,
                format: (v) => '${v.round()}',
                onChanged: (v) => _set(_with(jpegQuality: v.round())),
              ),
            ],
          ),
        ];
      case ConversionType.pdfToXlsx || ConversionType.pdfToCsv:
        return [
          if (t == ConversionType.pdfToXlsx)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('One sheet per page'),
              subtitle: const Text('Otherwise one sheet per table'),
              value: o.sheetPerPage,
              onChanged: (v) => _set(_with(sheetPerPage: v)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Export text lines when no table is found'),
            value: o.allTextIfNoTable,
            onChanged: (v) => _set(_with(allTextIfNoTable: v)),
          ),
          ...ocrOpts,
        ];
      case ConversionType.pdfToPptx:
        return [
          const _Header('Slides'),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Visual')),
              ButtonSegment(value: true, label: Text('Editable')),
            ],
            selected: {o.pptxEditable},
            onSelectionChanged: (s) => _set(_with(pptxEditable: s.first)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(o.pptxEditable
                ? 'Text boxes and pictures you can edit. Scanned pages become picture slides and are labelled as such.'
                : 'Each slide is a picture of the page: looks identical, text is not editable.'),
          ),
          _dpiSlider(),
        ];
      case ConversionType.pdfToImages:
        return [
          const _Header('Images'),
          SegmentedButton<RasterFormat>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: RasterFormat.jpg, label: Text('JPG')),
              ButtonSegment(value: RasterFormat.png, label: Text('PNG')),
              ButtonSegment(value: RasterFormat.tiff, label: Text('TIFF')),
            ],
            selected: {o.imageFormat},
            onSelectionChanged: (s) => _set(_with(imageFormat: s.first)),
          ),
          _dpiSlider(),
          if (o.imageFormat == RasterFormat.jpg)
            LabeledSlider(
              label: 'JPEG quality',
              value: o.jpegQuality.toDouble(),
              min: 40,
              max: 100,
              format: (v) => '${v.round()}',
              onChanged: (v) => _set(_with(jpegQuality: v.round())),
            ),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Grayscale'), value: o.grayscale, onChanged: (v) => _set(_with(grayscale: v))),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pack into one ZIP file'), value: o.zip, onChanged: (v) => _set(_with(zip: v))),
          TextField(
            controller: _template,
            decoration: const InputDecoration(labelText: 'File name template', helperText: '{name} = source name, {n} = page number'),
          ),
        ];
      case ConversionType.pdfToText || ConversionType.pdfToHtml:
        return ocrOpts;
      case ConversionType.imagesToPdf:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Fit on A4 pages'),
            subtitle: const Text('Otherwise each page is the size of its image'),
            value: o.fitToA4,
            onChanged: (v) => _set(_with(fitToA4: v)),
          ),
        ];
      case ConversionType.pptxToXlsx:
        return [
          const _Header('Extract'),
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Tables'), value: o.extractTables, onChanged: (v) => _set(_with(extractTables: v))),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Chart data'),
            subtitle: const Text('Only when the chart stores its data; values are never guessed from pictures'),
            value: o.extractCharts,
            onChanged: (v) => _set(_with(extractCharts: v)),
          ),
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Text, bullets and key: value pairs'), value: o.extractText, onChanged: (v) => _set(_with(extractText: v))),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('One text sheet per slide'), value: o.slideSheets, onChanged: (v) => _set(_with(slideSheets: v))),
        ];
      case ConversionType.xlsxToPptx:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add chart slides'),
            subtitle: const Text('Bar charts for numeric columns'),
            value: o.charts,
            onChanged: (v) => _set(_with(charts: v)),
          ),
        ];
      default:
        return const [];
    }
  }

  Widget _dpiSlider() => LabeledSlider(
        label: 'Resolution',
        value: _o.dpi,
        min: 72,
        max: 300,
        format: (v) => '${v.round()} dpi',
        onChanged: (v) => _set(_with(dpi: v.roundToDouble())),
      );
}

String _limitNote(ConversionType t) => switch (t) {
      ConversionType.pdfToDocx => 'Each PDF page becomes one Word page of the same size. Editable mode rebuilds text at its original position; fonts are matched or estimated, and the notes after conversion say what may differ. Nothing is uploaded: OCR runs on this device.',
      ConversionType.pdfToXlsx || ConversionType.pdfToCsv => 'Tables are detected from ruled lines or aligned columns. Uncertain cells keep their original text and are flagged. Review tables before exporting to fix columns.',
      ConversionType.pdfToPptx => 'Editable slides use text boxes positioned like the PDF; exact fonts and vector graphics are not reproduced.',
      ConversionType.docxToPdf || ConversionType.xlsxToPdf || ConversionType.pptxToPdf =>
        'Office files are rendered by the app itself (no Microsoft Office or cloud service). Text, tables, lists, pictures and simple charts are kept; exact fonts, shapes, SmartArt and advanced formatting are approximated.',
      ConversionType.htmlToPdf => 'Basic HTML only: CSS layout, scripts and images from the web are not used (nothing is downloaded).',
      ConversionType.pptxToXlsx => 'Only data stored in the slides is extracted. Charts that are pictures have no data to extract.',
      ConversionType.xlsxToPptx => 'Large tables are split over several slides so they stay readable.',
      _ => 'Converted on this device.',
    };

class _InfoNote extends StatelessWidget {
  final String text;
  const _InfoNote({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}

String _fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// The job queue and conversion history.
class ConversionJobsScreen extends StatelessWidget {
  const ConversionJobsScreen({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<DocSuite>(
        future: DocSuite.get(),
        builder: (ctx, snap) {
          final suite = snap.data;
          if (suite == null) return Scaffold(appBar: AppBar(title: const Text('Conversions')), body: const Center(child: CircularProgressIndicator()));
          final m = suite.jobs;
          return ListenableBuilder(
            listenable: m,
            builder: (ctx, _) {
              final overall = m.overallProgress;
              return Scaffold(
                appBar: AppBar(
                  title: const Text('Conversions'),
                  actions: [
                    if (m.jobs.any((j) => !j.active))
                      IconButton(
                        tooltip: 'Clear finished',
                        icon: const Icon(Icons.clear_all),
                        onPressed: () async {
                          if (await confirm(context, 'Clear history?', 'Finished, failed and cancelled jobs and their output files are removed from the app. Files you saved or shared are not affected.', ok: 'Clear')) {
                            await m.clearFinished();
                          }
                        },
                      ),
                  ],
                  bottom: overall == null ? null : PreferredSize(preferredSize: const Size.fromHeight(4), child: LinearProgressIndicator(value: overall)),
                ),
                floatingActionButton: FloatingActionButton.extended(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConversionCentreScreen())),
                  icon: const Icon(Icons.add),
                  label: const Text('New conversion'),
                ),
                body: m.jobs.isEmpty
                    ? const EmptyState(icon: Icons.swap_horiz, title: 'No conversions yet', message: 'Converted files appear here.')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                        itemCount: m.jobs.length,
                        itemBuilder: (ctx, i) => _JobCard(job: m.jobs[i], manager: m),
                      ),
              );
            },
          );
        },
      );
}

class _JobCard extends StatelessWidget {
  final ConversionJob job;
  final ConversionJobManager manager;
  const _JobCard({required this.job, required this.manager});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (job.status) {
      JobStatus.queued => (Icons.schedule, cs.onSurfaceVariant, 'Queued'),
      JobStatus.running => (Icons.autorenew, cs.primary, 'Converting'),
      JobStatus.done => (Icons.check_circle, Colors.green.shade700, 'Done'),
      JobStatus.failed => (Icons.error_outline, cs.error, 'Failed'),
      JobStatus.cancelled => (Icons.cancel_outlined, cs.onSurfaceVariant, 'Cancelled'),
      JobStatus.interrupted => (Icons.warning_amber, Colors.orange.shade800, 'Interrupted'),
    };
    final names = job.inputs.map((i) => i.name).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('${job.type.label} · $label', style: const TextStyle(fontWeight: FontWeight.w600))),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(context, v),
              itemBuilder: (_) => [
                if (job.active) const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                if (job.canRetry) const PopupMenuItem(value: 'retry', child: Text('Retry')),
                if (job.outputs.length > 1) const PopupMenuItem(value: 'zip', child: Text('Share all as ZIP')),
                const PopupMenuItem(value: 'remove', child: Text('Remove from history')),
              ],
            ),
          ]),
          Text(names.length <= 2 ? names.join(', ') : '${names.take(2).join(', ')} +${names.length - 2} more', maxLines: 2, overflow: TextOverflow.ellipsis),
          if (job.status == JobStatus.running) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: job.progress == 0 ? null : job.progress),
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(job.message, style: const TextStyle(fontSize: 12))),
          ],
          if (job.error != null) Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Text(job.error!, style: TextStyle(color: cs.error))),
          if (job.active && job.status == JobStatus.queued) const Text('Waiting for the job before it…', style: TextStyle(fontSize: 12)),
          if (job.canRetry)
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => _retry(context), icon: const Icon(Icons.refresh), label: const Text('Retry'))),
          if (job.status == JobStatus.running)
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => manager.cancel(job), icon: const Icon(Icons.stop), label: const Text('Cancel'))),
          if (job.warnings.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.info_outline, color: Colors.orange.shade800, size: 20),
                title: Text('${job.warnings.length} note(s) about this conversion', style: const TextStyle(fontSize: 13)),
                children: [for (final w in job.warnings) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('• $w', style: const TextStyle(fontSize: 12)))],
              ),
            ),
          for (final o in job.outputs.take(job.outputs.length > 6 ? 5 : 6)) _OutputTile(output: o),
          if (job.outputs.length > 6)
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _OutputsScreen(job: job))),
              child: Text('Show all ${job.outputs.length} files'),
            ),
        ]),
      ),
    );
  }

  Future<void> _retry(BuildContext context) async {
    final pw = <String, String>{};
    for (final i in job.inputs.where((i) => i.encrypted && !job.passwords.containsKey(i.name))) {
      final v = await promptText(context, 'Password for "${i.name}"', hint: 'PDF password', obscure: true, ok: 'Retry');
      if (v == null) return;
      pw[i.name] = v;
    }
    if (job.status == JobStatus.failed && (job.error ?? '').contains('password')) {
      for (final i in job.inputs.where((i) => !pw.containsKey(i.name) && job.inputs.length == 1)) {
        if (!context.mounted) return;
        final v = await promptText(context, 'Password for "${i.name}"', hint: 'PDF password', obscure: true, ok: 'Retry');
        if (v == null) return;
        pw[i.name] = v;
      }
    }
    await manager.retry(job, passwords: pw);
  }

  Future<void> _menu(BuildContext context, String v) async {
    switch (v) {
      case 'cancel':
        manager.cancel(job);
      case 'retry':
        await _retry(context);
      case 'zip':
        final a = Archive();
        for (final o in job.outputs) {
          final b = await File(o.path).readAsBytes();
          a.addFile(ArchiveFile(o.name, b.length, b));
        }
        await ExportActions.shareBytes(Uint8List.fromList(ZipEncoder().encode(a)!), '${job.outputName}.zip', mime: 'application/zip');
      case 'remove':
        if (job.outputs.isEmpty || await confirm(context, 'Remove?', 'The converted files kept in the app are deleted. Files you saved or shared are not affected.', ok: 'Remove', destructive: true)) {
          await manager.remove(job);
        }
    }
  }
}

class _OutputsScreen extends StatelessWidget {
  final ConversionJob job;
  const _OutputsScreen({required this.job});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('${job.outputs.length} files')),
        body: ListView(padding: const EdgeInsets.all(8), children: [for (final o in job.outputs) _OutputTile(output: o)]),
      );
}

class _OutputTile extends StatelessWidget {
  final ConversionOutput output;
  const _OutputTile({required this.output});

  @override
  Widget build(BuildContext context) {
    final exists = File(output.path).existsSync();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(output.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(exists ? _fmtSize(output.size) : 'File no longer available'),
      onTap: exists ? () => openOutput(context, output.path, output.name) : null,
      trailing: !exists
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) async {
                final bytes = await File(output.path).readAsBytes();
                if (!context.mounted) return;
                switch (v) {
                  case 'preview':
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(output.name)),
                        body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: OutputPreview(path: output.path, name: output.name)),
                      ),
                    ));
                  case 'open':
                    await openOutput(context, output.path, output.name);
                  case 'review':
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrReviewScreen(docxPath: output.path, name: output.name)));
                  case 'share':
                    await ExportActions.shareBytes(bytes, output.name, mime: mimeFor(output.name));
                  case 'save':
                    final r = await ExportActions.saveBytes(bytes, output.name);
                    if (r != null && context.mounted) showSnack(context, 'Saved');
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'preview', child: Text('Preview')),
                const PopupMenuItem(value: 'open', child: Text('Open')),
                if (OcrReviewScreen.available(output.path)) const PopupMenuItem(value: 'review', child: Text('Review OCR words')),
                const PopupMenuItem(value: 'share', child: Text('Share / open with…')),
                const PopupMenuItem(value: 'save', child: Text('Save to device')),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  const _Header(this.title);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      );
}
