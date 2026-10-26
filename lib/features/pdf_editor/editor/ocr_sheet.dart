import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/ocr_models.dart';
import '../../../core/storage.dart';
import '../../../shared/widgets.dart';
import '../../ocr/ocr_service.dart';
import '../engine/engine_worker.dart';
import '../model/edit_state.dart';
import 'editor_controller.dart';

/// OCR-assisted editing for scanned pages. It never changes the scan:
/// corrected text is either added as an invisible, searchable layer, or a
/// line is visibly replaced by covering it and placing new text on top.
class OcrEditScreen extends StatefulWidget {
  final PdfEditorController c;
  const OcrEditScreen({super.key, required this.c});

  @override
  State<OcrEditScreen> createState() => _OcrEditScreenState();
}

class _Line {
  final OcrLine ocr;
  final Rect box; // display points
  final TextEditingController text;
  _Line(this.ocr, this.box) : text = TextEditingController(text: ocr.text);
}

class _OcrEditScreenState extends State<OcrEditScreen> {
  static const _scale = 2.5; // render pixels per point for OCR
  String _script = 'latin';
  bool _busy = false;
  String? _error;
  List<_Line> _lines = [];
  RenderedPage? _page;

  PdfEditorController get c => widget.c;

  @override
  void dispose() {
    for (final l in _lines) {
      l.text.dispose();
    }
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ocr = OcrService();
    try {
      final page = await c.engine.render(c.state, c.slot.id, _scale, original: true);
      _page = page;
      final png = await compute(_encodePng, (page.rgba, page.width, page.height));
      final path = AppStorage.instance.tempPath('ocr_page.png');
      await File(path).writeAsBytes(png);
      try {
        final r = await ocr.recognizeFile(path, script: _script, imageWidth: page.width, imageHeight: page.height);
        setState(() {
          _lines = [
            for (final l in r.lines)
              if (l.text.trim().isNotEmpty) _Line(l, Rect.fromLTRB(l.left / _scale, l.top / _scale, l.right / _scale, l.bottom / _scale)),
          ];
        });
      } finally {
        await File(path).delete().catchError((_) => File(path));
      }
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      await ocr.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  static Uint8List _encodePng((Uint8List, int, int) a) {
    final (rgba, w, h) = a;
    final im = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    return Uint8List.fromList(img.encodePng(im, level: 1));
  }

  void _addLayer() {
    var st = c.state;
    // Replace an earlier OCR layer on this page.
    for (final it in st.itemsOn(c.slot.id).where((i) => i.kind == ItemKind.ocrText)) {
      st = st.withoutItem(it.id);
    }
    for (final l in _lines) {
      final t = l.text.text.trim();
      if (t.isEmpty) continue;
      st = st.withItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.ocrText, box: l.box, text: t));
    }
    c.apply(st);
    showSnack(context, 'Searchable text layer added (${_lines.length} lines). The scan itself is unchanged.');
  }

  /// Median colour of the pixels just around the line: the paper colour.
  int _paperColour(Rect box) {
    final p = _page;
    if (p == null) return 0xFFFFFFFF;
    final r = Rect.fromLTRB(box.left * _scale - 3, box.top * _scale - 3, box.right * _scale + 3, box.bottom * _scale + 3);
    final samples = <int>[];
    void at(int x, int y) {
      if (x < 0 || y < 0 || x >= p.width || y >= p.height) return;
      final i = (y * p.width + x) * 4;
      samples.add((p.rgba[i] << 16) | (p.rgba[i + 1] << 8) | p.rgba[i + 2]);
    }

    for (var x = r.left.floor(); x <= r.right.ceil(); x += 2) {
      at(x, r.top.floor());
      at(x, r.bottom.ceil());
    }
    for (var y = r.top.floor(); y <= r.bottom.ceil(); y += 2) {
      at(r.left.floor(), y);
      at(r.right.ceil(), y);
    }
    if (samples.isEmpty) return 0xFFFFFFFF;
    int ch(int v, int s) => (v >> s) & 0xFF;
    int med(int s) {
      final l = samples.map((v) => ch(v, s)).toList()..sort();
      return l[l.length ~/ 2];
    }

    return 0xFF000000 | (med(16) << 16) | (med(8) << 8) | med(0);
  }

  Future<void> _replaceVisually(_Line l) async {
    final ok = await confirm(
      context,
      'Replace this line visually?',
      'A rectangle in the paper colour will cover the scanned line and your corrected text will be placed on top. '
          'The scan underneath is not changed, so the cover can be removed later in the editor. Check the result carefully.',
      ok: 'Replace',
    );
    if (!ok) return;
    final box = l.box.inflate(1.5);
    final size = math.max(5.0, l.box.height * 0.78);
    var st = c.state.withItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.cover, box: box, color: _paperColour(l.box)));
    st = st.withItem(EditItem(
      id: c.newItemId(),
      slot: c.slot.id,
      kind: ItemKind.text,
      box: Rect.fromLTWH(l.box.left, l.box.top - size * 0.08, math.max(l.box.width * 1.5, 40), l.box.height),
      text: l.text.text.trim(),
      style: TextStyleSpec(size: double.parse(size.toStringAsFixed(1)), font: FontChoice.helvetica),
    ));
    c.apply(st);
    if (mounted) showSnack(context, 'Line replaced with an overlay. Review it on the page.');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = c.analysis;
    return Scaffold(
      appBar: AppBar(title: const Text('Scanned page text (OCR)')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: t.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              a != null && a.looksScanned
                  ? 'This page is a picture of a document. It has no editable PDF text, so its words cannot be changed in place.\n\n'
                      '• Recognise text: reads the picture with on-device OCR so you can correct it.\n'
                      '• Searchable layer: adds your corrected text invisibly behind the scan so the PDF can be searched and copied. The visible scan does not change.\n'
                      '• Replace visually: covers a line and places new text on top. This changes what the page looks like, not the scanned image underneath.'
                  : 'This page has PDF text. Use Edit Text to change it directly. OCR is still available here for text that is part of an image.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Language: '),
          DropdownButton<String>(
            value: _script,
            items: [for (final s in OcrScript.all) DropdownMenuItem(value: s.id, child: Text(s.label))],
            onChanged: _busy ? null : (v) => setState(() => _script = v ?? 'latin'),
          ),
          const Spacer(),
          FilledButton.icon(onPressed: _busy ? null : _run, icon: const Icon(Icons.document_scanner_outlined), label: Text(_lines.isEmpty ? 'Recognise text' : 'Run again')),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
        if (_lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(onPressed: _addLayer, icon: const Icon(Icons.layers_outlined), label: const Text('Add as searchable text layer')),
          const SizedBox(height: 8),
          Text('${_lines.length} lines. Lines marked ⚠ may be misread. Correct them before using them.', style: t.textTheme.bodySmall),
          for (final l in _lines)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: l.text,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        prefixText: l.ocr.flagged ? '⚠ ' : null,
                        helperText: l.ocr.confidence == null ? 'Confidence not reported' : 'Confidence ${(l.ocr.confidence! * 100).round()}%',
                      ),
                    ),
                  ),
                  IconButton(onPressed: () => _replaceVisually(l), icon: const Icon(Icons.find_replace), tooltip: 'Replace this line visually'),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}
