import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/units.dart';
import '../../shared/widgets.dart';
import 'pdf_service.dart';
import 'pdf_viewer_screen.dart';

/// PDF export options for a scanned document.
class PdfExportScreen extends ConsumerStatefulWidget {
  final ScanDocument document;
  final List<DocPage> pages;
  const PdfExportScreen({super.key, required this.document, required this.pages});

  @override
  ConsumerState<PdfExportScreen> createState() => _PdfExportScreenState();
}

class _PdfExportScreenState extends ConsumerState<PdfExportScreen> {
  late String _sizeId = ref.read(settingsProvider).defaultPageSize;
  bool _auto = true;
  bool _landscape = false;
  FitMode _fit = FitMode.fit;
  double _margin = 0;
  bool _numbers = false;
  late bool _searchable = widget.pages.any((p) => p.hasOcr);
  bool _gray = false;
  CompressionPreset _quality = CompressionPreset.standard;
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _author = TextEditingController();
  final _subject = TextEditingController();
  final _keywords = TextEditingController();
  final _watermark = TextEditingController();
  bool _protect = false;
  bool _showMeta = false;

  @override
  void dispose() {
    for (final c in [_password, _password2, _author, _subject, _keywords, _watermark]) {
      c.dispose();
    }
    super.dispose();
  }

  PaperSize? get _size => _sizeId == 'match' ? null : PaperSizes.byId(_sizeId);

  Future<void> _export() async {
    if (_protect) {
      if (_password.text.length < 4) {
        showSnack(context, 'Use a password with at least 4 characters');
        return;
      }
      if (_password.text != _password2.text) {
        showSnack(context, 'Passwords do not match');
        return;
      }
    }
    final repo = ref.read(repositoryProvider);
    final missingOcr = widget.pages.where((p) => !p.hasOcr).length;
    if (_searchable && missingOcr > 0) {
      final go = await confirm(context, 'Some pages have no OCR text',
          '$missingOcr page(s) have not been recognised yet, so they will not be searchable. Run OCR from the document menu first, or continue.',
          ok: 'Continue');
      if (!go) return;
    }
    if (!mounted) return;
    final opts = PdfExportOptions(
      pageSize: _size,
      landscape: _landscape,
      autoOrientation: _auto,
      fit: _fit,
      marginMm: _margin,
      pageNumbers: _numbers,
      searchable: _searchable,
      password: _protect ? _password.text : null,
      title: widget.document.title,
      author: _author.text.trim(),
      subject: _subject.text.trim(),
      keywords: _keywords.text.trim(),
      maxDim: _quality.maxDim,
      quality: _quality.quality,
      grayscale: _gray,
      watermark: _watermark.text.trim().isEmpty ? null : _watermark.text.trim(),
    );
    final bytes = await runBusy(context, 'Creating PDF…', (ctl) {
      return PdfService.buildFromPages(
        widget.pages,
        opts,
        ocrFor: repo.loadOcr,
        onProgress: (d, t) => ctl.update('Adding page $d of $t…', d / t),
        isCancelled: () => ctl.cancelled,
      );
    }, cancellable: true);
    if (bytes == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(
        bytes: bytes,
        title: widget.document.title,
        parentId: widget.document.id,
        password: _protect ? _password.text : null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Export PDF')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        Text('${widget.pages.length} page(s) · ${widget.document.title}', style: t.textTheme.bodyMedium),
        const SectionHeader('Page size'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(label: const Text('Match image'), selected: _sizeId == 'match', onSelected: (_) => setState(() => _sizeId = 'match')),
          for (final s in PaperSizes.documentSizes)
            ChoiceChip(label: Text(s.name), selected: _sizeId == s.id, onSelected: (_) => setState(() => _sizeId = s.id)),
        ]),
        if (_size != null) ...[
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.screen_rotation_alt)),
              ButtonSegment(value: 'portrait', label: Text('Portrait'), icon: Icon(Icons.crop_portrait)),
              ButtonSegment(value: 'landscape', label: Text('Landscape'), icon: Icon(Icons.crop_landscape)),
            ],
            selected: {_auto ? 'auto' : (_landscape ? 'landscape' : 'portrait')},
            onSelectionChanged: (s) => setState(() {
              _auto = s.first == 'auto';
              _landscape = s.first == 'landscape';
            }),
          ),
          const SizedBox(height: 12),
          SegmentedButton<FitMode>(
            segments: [for (final f in FitMode.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {_fit},
            onSelectionChanged: (s) => setState(() => _fit = s.first),
          ),
          LabeledSlider(
            label: 'Margins',
            value: _margin,
            min: 0,
            max: 25,
            format: (v) => '${v.round()} mm',
            onChanged: (v) => setState(() => _margin = v.roundToDouble()),
          ),
        ],
        const SectionHeader('Quality & size'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final q in CompressionPreset.all)
            ChoiceChip(
              label: Text(q.label),
              selected: _quality.id == q.id,
              onSelected: (_) => setState(() => _quality = q),
              tooltip: q.hint,
            ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('${_quality.hint} · images up to ${_quality.maxDim}px, JPEG ${_quality.quality}%', style: t.textTheme.bodySmall),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Grayscale'),
          subtitle: const Text('Smaller files for text documents'),
          value: _gray,
          onChanged: (v) => setState(() => _gray = v),
        ),
        const SectionHeader('Content'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Searchable PDF (OCR text layer)'),
          subtitle: Text(widget.pages.any((p) => p.hasOcr)
              ? 'Adds invisible recognised text so the PDF can be searched and copied'
              : 'Run OCR on this document first to enable'),
          value: _searchable,
          onChanged: widget.pages.any((p) => p.hasOcr) ? (v) => setState(() => _searchable = v) : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Page numbers'),
          value: _numbers,
          onChanged: (v) => setState(() => _numbers = v),
        ),
        TextField(controller: _watermark, decoration: const InputDecoration(labelText: 'Watermark text (optional)', hintText: 'e.g. COPY, CONFIDENTIAL')),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Password protect (AES-256)'),
          subtitle: const Text('Required to open the PDF. Different from app storage encryption.'),
          value: _protect,
          onChanged: (v) => setState(() => _protect = v),
        ),
        if (_protect) ...[
          TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 8),
          TextField(controller: _password2, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('The password is not stored by the app. If you forget it the PDF cannot be opened.', style: t.textTheme.bodySmall),
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Metadata'),
          initiallyExpanded: _showMeta,
          onExpansionChanged: (v) => _showMeta = v,
          children: [
            TextField(controller: _author, decoration: const InputDecoration(labelText: 'Author')),
            const SizedBox(height: 8),
            TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Subject')),
            const SizedBox(height: 8),
            TextField(controller: _keywords, decoration: const InputDecoration(labelText: 'Keywords')),
            const SizedBox(height: 8),
          ],
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(onPressed: _export, icon: const Icon(Icons.picture_as_pdf), label: const Text('Create PDF')),
        ),
      ),
    );
  }
}
