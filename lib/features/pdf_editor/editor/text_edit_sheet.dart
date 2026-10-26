import 'package:flutter/material.dart';

import '../engine/pdf_edit_engine.dart';
import '../model/edit_state.dart';

const editorPalette = <int>[0xFF000000, 0xFF424242, 0xFF0D47A1, 0xFF1565C0, 0xFFC62828, 0xFF2E7D32, 0xFF6A1B9A, 0xFFEF6C00, 0xFFFFFFFF];

/// Result of the text sheet.
class TextSheetResult {
  final String text;
  final TextStyleSpec style;
  final bool shrinkToFit;
  final bool styleChanged;
  const TextSheetResult(this.text, this.style, {this.shrinkToFit = false, this.styleChanged = true});
}

/// Bottom sheet to edit existing text (with [block]) or new text.
/// [preview] lays the edit out with the PDF engine and reports the font
/// actually used and any warnings before the user applies it.
Future<TextSheetResult?> showTextEditSheet(
  BuildContext context, {
  required String initialText,
  required TextStyleSpec initialStyle,
  TextBlockInfo? block,
  bool initialShrink = false,
  Future<TextEditReport> Function(String text, TextStyleSpec style, bool shrink)? preview,
  String title = 'Edit text',
}) {
  return showModalBottomSheet<TextSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _TextEditSheet(
      initialText: initialText,
      initialStyle: initialStyle,
      block: block,
      initialShrink: initialShrink,
      preview: preview,
      title: title,
    ),
  );
}

class _TextEditSheet extends StatefulWidget {
  final String initialText;
  final TextStyleSpec initialStyle;
  final TextBlockInfo? block;
  final bool initialShrink;
  final Future<TextEditReport> Function(String text, TextStyleSpec style, bool shrink)? preview;
  final String title;
  const _TextEditSheet({required this.initialText, required this.initialStyle, this.block, required this.initialShrink, this.preview, required this.title});

  @override
  State<_TextEditSheet> createState() => _TextEditSheetState();
}

class _TextEditSheetState extends State<_TextEditSheet> {
  late final TextEditingController _text = TextEditingController(text: widget.initialText);
  late TextStyleSpec _style = widget.initialStyle;
  late bool _shrink = widget.initialShrink;
  TextEditReport? _report;
  bool _previewing = false;
  String? _previewError;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _runPreview() async {
    final p = widget.preview;
    if (p == null) return;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final r = await p(_text.text, _style, _shrink);
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _previewError = e.toString());
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  void _set(TextStyleSpec s) => setState(() {
        _style = s;
        _report = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = widget.block;
    final fonts = [if (b != null) FontChoice.original, FontChoice.helvetica, FontChoice.times, FontChoice.courier, FontChoice.unicodeSans];
    final colors = {...editorPalette, if (b != null) b.first.color | 0xFF000000}.toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title, style: t.textTheme.titleLarge),
          if (b != null) ...[
            const SizedBox(height: 4),
            Text('Original: ${b.first.font.describe} · ${b.first.size.toStringAsFixed(1)} pt', style: t.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(border: OutlineInputBorder(), helperText: 'Press Enter for a new line. Text wraps inside the box automatically.'),
            onChanged: (_) => setState(() => _report = null),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<FontChoice>(
              value: fonts.contains(_style.font) ? _style.font : fonts.first,
              items: [for (final f in fonts) DropdownMenuItem(value: f, child: Text(f.label))],
              onChanged: (v) => v == null ? null : _set(_style.copyWith(font: v)),
            ),
            _SizeStepper(value: _style.size, onChanged: (v) => _set(_style.copyWith(size: v))),
            FilterChip(label: const Text('B', style: TextStyle(fontWeight: FontWeight.bold)), selected: _style.bold, onSelected: (v) => _set(_style.copyWith(bold: v)), tooltip: 'Bold'),
            FilterChip(label: const Text('I', style: TextStyle(fontStyle: FontStyle.italic)), selected: _style.italic, onSelected: (v) => _set(_style.copyWith(italic: v)), tooltip: 'Italic'),
          ]),
          const SizedBox(height: 8),
          SegmentedButton<TextAlign2>(
            segments: const [
              ButtonSegment(value: TextAlign2.left, icon: Icon(Icons.format_align_left), tooltip: 'Left'),
              ButtonSegment(value: TextAlign2.center, icon: Icon(Icons.format_align_center), tooltip: 'Centre'),
              ButtonSegment(value: TextAlign2.right, icon: Icon(Icons.format_align_right), tooltip: 'Right'),
              ButtonSegment(value: TextAlign2.justify, icon: Icon(Icons.format_align_justify), tooltip: 'Justify'),
            ],
            selected: {_style.align},
            onSelectionChanged: (s) => _set(_style.copyWith(align: s.first)),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in colors)
              InkWell(
                onTap: () => _set(_style.copyWith(color: c)),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: (_style.color | 0xFF000000) == c ? t.colorScheme.primary : Colors.grey, width: (_style.color | 0xFF000000) == c ? 3 : 1),
                  ),
                ),
              ),
          ]),
          Row(children: [
            const SizedBox(width: 110, child: Text('Line spacing')),
            Expanded(
              child: Slider(
                value: _style.lineSpacing.clamp(0.8, 2.5),
                min: 0.8,
                max: 2.5,
                divisions: 34,
                label: _style.lineSpacing.toStringAsFixed(2),
                onChanged: (v) => _set(_style.copyWith(lineSpacing: double.parse(v.toStringAsFixed(2)))),
              ),
            ),
            Text('${_style.lineSpacing.toStringAsFixed(2)}×'),
          ]),
          if (b != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep inside the original box'),
              subtitle: const Text('Reduces the font size if the new text is longer'),
              value: _shrink,
              onChanged: (v) => setState(() {
                _shrink = v;
                _report = null;
              }),
            ),
          const Text('Character spacing is kept only when text is changed within one line in its original font; it cannot be adjusted here.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          if (widget.preview != null) ...[
            const SizedBox(height: 8),
            if (_previewing) const LinearProgressIndicator(),
            if (_previewError != null) Text(_previewError!, style: TextStyle(color: t.colorScheme.error)),
            if (_report != null) _ReportView(report: _report!),
          ],
          const SizedBox(height: 12),
          Row(children: [
            if (widget.preview != null) OutlinedButton.icon(onPressed: _previewing ? null : _runPreview, icon: const Icon(Icons.fact_check_outlined), label: const Text('Check font & layout')),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _text.text.trim().isEmpty && b == null
                  ? null
                  : () => Navigator.pop(context, TextSheetResult(_text.text, _style, shrinkToFit: _shrink, styleChanged: _style != widget.initialStyle)),
              child: const Text('Apply'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _ReportView extends StatelessWidget {
  final TextEditReport report;
  const _ReportView({required this.report});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ok = report.originalFontUsed;
    return Card(
      color: ok && report.warnings.isEmpty ? t.colorScheme.primaryContainer : t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_outline : Icons.font_download_outlined, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ok
                    ? (report.inPlace ? 'Original font reused; text changed in place.' : 'Original font reused.')
                    : 'Font used: ${report.fontUsed} (substitute, not the original font).',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          for (final w in report.warnings) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $w')),
          if (report.warnings.isEmpty && ok) const Padding(padding: EdgeInsets.only(top: 4), child: Text('No layout problems found. Review the page after applying.')),
        ]),
      ),
    );
  }
}

class _SizeStepper extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _SizeStepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(onPressed: value > 4 ? () => onChanged(double.parse((value - 0.5).toStringAsFixed(1))) : null, icon: const Icon(Icons.remove), tooltip: 'Smaller'),
      Text('${value.toStringAsFixed(1)} pt'),
      IconButton(onPressed: value < 144 ? () => onChanged(double.parse((value + 0.5).toStringAsFixed(1))) : null, icon: const Icon(Icons.add), tooltip: 'Larger'),
    ]);
  }
}
