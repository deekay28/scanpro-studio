import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../shared/widgets.dart';
import '../pdf/export_actions.dart';
import 'ocr_service.dart';
import 'text_analysis.dart';

/// OCR workspace: language selection, page/all recognition, review of
/// uncertain lines, editing, copy/TXT/CSV export and extracted fields.
class OcrScreen extends ConsumerStatefulWidget {
  final String docId;
  final String? initialPageId;
  const OcrScreen({super.key, required this.docId, this.initialPageId});

  static List<String> nameSuggestions(String text) => TextAnalysis.suggestNames(text);

  @override
  ConsumerState<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends ConsumerState<OcrScreen> {
  ScanDocument? _doc;
  List<DocPage> _pages = const [];
  int _index = 0;
  OcrPageResult? _result;
  late String _script = ref.read(settingsProvider).ocrScript;
  bool _loading = true;
  bool _showBoxes = false;
  bool _onlyFlagged = false;

  DocumentRepository get _repo => ref.read(repositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await _repo.getDocument(widget.docId);
    final pages = await _repo.getPages(widget.docId);
    var idx = 0;
    if (widget.initialPageId != null) {
      final i = pages.indexWhere((p) => p.id == widget.initialPageId);
      if (i >= 0) idx = i;
    }
    if (!mounted) return;
    setState(() {
      _doc = d;
      _pages = pages;
      _index = idx;
      _loading = false;
    });
    await _loadResult();
  }

  Future<void> _loadResult() async {
    if (_pages.isEmpty) return;
    final fresh = await _repo.getPage(_pages[_index].id);
    if (fresh == null) return;
    final r = await _repo.loadOcr(fresh);
    if (!mounted) return;
    setState(() {
      _pages = [..._pages]..[_index] = fresh;
      _result = r;
    });
  }

  Future<void> _recognize({bool all = false}) async {
    final targets = all ? List.generate(_pages.length, (i) => i) : [_index];
    await runBusy<void>(context, 'Recognising text…', (ctl) async {
      for (var k = 0; k < targets.length; k++) {
        if (ctl.cancelled) break;
        ctl.update('Recognising page ${targets[k] + 1} of ${_pages.length}…', (k + 1) / targets.length);
        final page = (await _repo.getPage(_pages[targets[k]].id))!;
        await ocrService.recognizePage(_repo, page, _script);
      }
    }, cancellable: all);
    final pages = await _repo.getPages(widget.docId);
    if (!mounted) return;
    setState(() => _pages = pages);
    await _loadResult();
    final text = pages.map((p) => p.ocrText ?? '').join('\n');
    final type = TextAnalysis.classify(text);
    if (type != null && _doc?.docType == null) await _repo.setDocType(widget.docId, type);
    if (mounted && _result != null) {
      final flagged = _result!.flaggedCount;
      showSnack(context,
          _result!.lines.isEmpty ? 'No text found on this page' : '${_result!.lines.length} lines recognised${flagged > 0 ? ' · $flagged need review' : ''}');
    }
  }

  Future<void> _editLine(int i) async {
    final r = _result;
    if (r == null) return;
    final l = r.lines[i];
    final text = await promptText(context, 'Correct text', initial: l.text, ok: 'Save');
    if (text == null) return;
    final lines = [...r.lines];
    lines[i] = l.copyWith(text: text, flagged: false);
    await _saveResult(r.copyWith(lines: lines, edited: true));
  }

  Future<void> _markReviewed(int i) async {
    final r = _result!;
    final lines = [...r.lines];
    lines[i] = lines[i].copyWith(flagged: false);
    await _saveResult(r.copyWith(lines: lines));
  }

  Future<void> _saveResult(OcrPageResult r) async {
    final page = (await _repo.getPage(_pages[_index].id))!;
    await _repo.saveOcr(page, r);
    await _loadResult();
  }

  Future<void> _editAll() async {
    final r = _result;
    if (r == null) return;
    final c = TextEditingController(text: r.text);
    final saved = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(
          title: const Text('Edit text'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save'))],
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(controller: c, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top, decoration: const InputDecoration(border: OutlineInputBorder())),
        ),
      ),
    ));
    if (saved == null) return;
    // Map edited lines back onto boxes where line counts match; otherwise keep
    // the full text in one block so search and export still use it.
    final newLines = saved.split('\n').where((l) => l.trim().isNotEmpty).toList();
    List<OcrLine> lines;
    if (newLines.length == r.lines.length) {
      lines = [for (var i = 0; i < newLines.length; i++) r.lines[i].copyWith(text: newLines[i], flagged: false)];
    } else {
      final first = r.lines.isNotEmpty ? r.lines.first : const OcrLine(text: '', left: 0, top: 0, right: 0, bottom: 0);
      lines = [
        for (var i = 0; i < newLines.length; i++)
          OcrLine(text: newLines[i], left: first.left, top: first.top, right: first.right, bottom: first.bottom, block: 0),
      ];
    }
    await _saveResult(r.copyWith(lines: lines, edited: true));
  }

  String get _allText => _pages.where((p) => p.ocrText != null).map((p) => p.ocrText!).join('\n\n— page break —\n\n');

  Future<void> _export(String what) async {
    final title = _doc?.title ?? 'Text';
    switch (what) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _result?.text ?? ''));
        if (mounted) showSnack(context, 'Page text copied');
      case 'copyall':
        await Clipboard.setData(ClipboardData(text: _allText));
        if (mounted) showSnack(context, 'All text copied');
      case 'txt':
        await ExportActions.shareBytes(Uint8List.fromList(_utf8(_allText)), Naming.withExtension(title, 'txt'), mime: 'text/plain');
      case 'csv':
        {
          final r = _result;
          if (r == null || r.lines.isEmpty) return;
          final table = TextAnalysis.extractTable(r.lines);
          final csv = TextAnalysis.toCsv(table);
          await ExportActions.shareBytes(Uint8List.fromList(_utf8('﻿$csv')), Naming.withExtension('$title p${_index + 1}', 'csv'), mime: 'text/csv');
        }
      case 'savetxt':
        await ExportActions.saveBytes(Uint8List.fromList(_utf8(_allText)), Naming.withExtension(title, 'txt'));
    }
  }

  List<int> _utf8(String s) => const Utf8Codec().encode(s);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final page = _pages.isEmpty ? null : _pages[_index];
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text('Text · Page ${_index + 1}/${_pages.length}'),
        actions: [
          IconButton(onPressed: r == null ? null : _editAll, icon: const Icon(Icons.edit_note), tooltip: 'Edit all text'),
          PopupMenuButton<String>(
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('Copy page text')),
              PopupMenuItem(value: 'copyall', child: Text('Copy all pages')),
              PopupMenuItem(value: 'txt', child: Text('Share as TXT')),
              PopupMenuItem(value: 'savetxt', child: Text('Save TXT to device')),
              PopupMenuItem(value: 'csv', child: Text('Export table as CSV (best effort)')),
            ],
          ),
        ],
      ),
      body: page == null
          ? const EmptyState(icon: Icons.text_snippet_outlined, title: 'No pages')
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(children: [
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _script,
                      items: [for (final s in OcrScript.all) DropdownMenuItem(value: s.id, child: Text(s.label))],
                      onChanged: (v) => setState(() => _script = v ?? 'latin'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: () => _recognize(), child: Text(r == null ? 'Recognise' : 'Retry page')),
                  const SizedBox(width: 6),
                  OutlinedButton(onPressed: () => _recognize(all: true), child: const Text('All')),
                ]),
              ),
              if (_pages.length > 1)
                SizedBox(
                  height: 64,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    itemCount: _pages.length,
                    itemBuilder: (ctx, i) => GestureDetector(
                      onTap: () {
                        setState(() {
                          _index = i;
                          _result = null;
                        });
                        _loadResult();
                      },
                      child: Container(
                        width: 40,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: i == _index ? Theme.of(ctx).colorScheme.primary : Colors.transparent, width: 2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Stack(fit: StackFit.expand, children: [
                          StoredImage(_pages[i].thumbPath, cacheWidth: 100),
                          if (_pages[i].hasOcr) const Align(alignment: Alignment.bottomRight, child: Icon(Icons.check_circle, size: 14, color: Colors.green)),
                        ]),
                      ),
                    ),
                  ),
                ),
              Expanded(child: r == null ? _noResult() : _resultView(page, r)),
            ]),
    );
  }

  Widget _noResult() => EmptyState(
        icon: Icons.document_scanner_outlined,
        title: 'Not recognised yet',
        message: 'Recognition runs entirely on this device. Choose the script of the document (Hindi/Devanagari also reads English).',
        action: FilledButton.icon(onPressed: () => _recognize(), icon: const Icon(Icons.text_fields), label: const Text('Recognise this page')),
      );

  Widget _resultView(DocPage page, OcrPageResult r) {
    final entities = TextAnalysis.extract(r.text);
    final scheme = Theme.of(context).colorScheme;
    final visible = [for (var i = 0; i < r.lines.length; i++) if (!_onlyFlagged || r.lines[i].flagged) i];
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 32), children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Chip(
          avatar: Icon(r.flaggedCount > 0 ? Icons.warning_amber : Icons.check, size: 16),
          label: Text(r.flaggedCount > 0 ? '${r.flaggedCount} line(s) to review' : 'No lines flagged'),
        ),
        FilterChip(label: const Text('Only flagged'), selected: _onlyFlagged, onSelected: (v) => setState(() => _onlyFlagged = v)),
        FilterChip(label: const Text('Show boxes'), selected: _showBoxes, onSelected: (v) => setState(() => _showBoxes = v)),
        Text(r.script == 'devanagari' ? 'Devanagari model' : 'Latin model', style: Theme.of(context).textTheme.bodySmall),
      ]),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text('OCR can make mistakes. Highlighted lines are uncertain — tap a line to correct it.', style: TextStyle(fontSize: 12)),
      ),
      if (_showBoxes)
        AspectRatio(
          aspectRatio: r.imageWidth > 0 && r.imageHeight > 0 ? r.imageWidth / r.imageHeight : 0.75,
          child: Stack(fit: StackFit.expand, children: [
            StoredImage(page.displayPath, fit: BoxFit.fill),
            CustomPaint(painter: _BoxPainter(r)),
          ]),
        ),
      if (!entities.isEmpty) _entitiesCard(entities),
      const SizedBox(height: 8),
      for (final i in visible)
        Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: r.lines[i].flagged ? Colors.amber.withValues(alpha: 0.22) : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            dense: true,
            title: SelectableText(r.lines[i].text),
            subtitle: r.lines[i].confidence != null ? Text('Confidence ${(r.lines[i].confidence! * 100).round()}%') : null,
            onTap: () => _editLine(i),
            trailing: r.lines[i].flagged
                ? IconButton(icon: const Icon(Icons.done), tooltip: 'Mark as correct', onPressed: () => _markReviewed(i))
                : null,
          ),
        ),
    ]);
  }

  Widget _entitiesCard(ExtractedEntities e) {
    Widget row(String label, List<String> values) => values.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 80, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final v in values.take(6))
                    ActionChip(
                      label: Text(v, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: v));
                        showSnack(context, 'Copied "$v"');
                      },
                    ),
                ]),
              ),
            ]),
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Detected fields (suggestions — verify)', style: TextStyle(fontWeight: FontWeight.w600)),
          if (e.total != null) row('Total', [e.total!]),
          row('Dates', e.dates),
          row('Amounts', e.amounts),
          row('Phones', e.phones),
          row('Emails', e.emails),
          row('Links', e.urls),
          row('GSTIN', e.gstins),
        ]),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final OcrPageResult r;
  _BoxPainter(this.r);
  @override
  void paint(Canvas canvas, Size size) {
    if (r.imageWidth == 0 || r.imageHeight == 0) return;
    final sx = size.width / r.imageWidth, sy = size.height / r.imageHeight;
    for (final l in r.lines) {
      canvas.drawRect(
        Rect.fromLTRB(l.left * sx, l.top * sy, l.right * sx, l.bottom * sy),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = l.flagged ? Colors.orange : Colors.green,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => old.r != r;
}
