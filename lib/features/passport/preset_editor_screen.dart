import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import 'photo_presets.dart';

/// Lists photo presets; built-ins can be edited (reset by deleting the
/// override) and custom presets can be added or removed.
class PresetEditorScreen extends ConsumerStatefulWidget {
  const PresetEditorScreen({super.key});

  @override
  ConsumerState<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends ConsumerState<PresetEditorScreen> {
  List<PhotoPreset>? _presets;
  late final PresetStore _store = PresetStore(ref.read(databaseProvider).db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _store.load();
    if (mounted) setState(() => _presets = p);
  }

  Future<void> _edit(PhotoPreset? preset) async {
    final result = await Navigator.of(context).push<PhotoPreset>(MaterialPageRoute(
      builder: (_) => PresetFormScreen(preset: preset ?? PhotoPreset(id: 'custom_${newId()}', name: 'Custom photo', category: 'custom', widthMm: 35, heightMm: 45)),
    ));
    if (result == null) return;
    await _store.save(result);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    return Scaffold(
      appBar: AppBar(title: const Text('Photo presets')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('New preset')),
      body: presets == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Sizes are common published values and are provided as a starting point only. '
                  'Requirements differ between countries, offices and applications and change over time — '
                  'always verify against the official guidance before printing.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              for (final p in presets)
                ListTile(
                  leading: Container(width: 28, height: 36, decoration: BoxDecoration(color: Color(p.backgroundArgb), border: Border.all(color: Colors.grey))),
                  title: Text(p.name),
                  subtitle: Text('${p.sizeLabel} · ${p.dpi} dpi · head ${(p.headMin * 100).round()}–${(p.headMax * 100).round()}%'),
                  onTap: () => _edit(p),
                  trailing: p.builtIn
                      ? IconButton(
                          tooltip: 'Reset to default',
                          icon: const Icon(Icons.restore),
                          onPressed: () async {
                            await _store.delete(p.id);
                            await _load();
                          },
                        )
                      : IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await confirm(context, 'Delete preset?', p.name, ok: 'Delete', destructive: true)) {
                              await _store.delete(p.id);
                              await _load();
                            }
                          },
                        ),
                ),
            ]),
    );
  }
}

class PresetFormScreen extends StatefulWidget {
  final PhotoPreset preset;
  const PresetFormScreen({super.key, required this.preset});

  @override
  State<PresetFormScreen> createState() => _PresetFormScreenState();
}

class _PresetFormScreenState extends State<PresetFormScreen> {
  late final _name = TextEditingController(text: widget.preset.name);
  late final _w = TextEditingController(text: widget.preset.widthMm.toString());
  late final _h = TextEditingController(text: widget.preset.heightMm.toString());
  late final _dpi = TextEditingController(text: widget.preset.dpi.toString());
  late final _notes = TextEditingController(text: widget.preset.notes);
  late double _headMin = widget.preset.headMin;
  late double _headMax = widget.preset.headMax;
  late double _top = widget.preset.topMargin;
  late int _bg = widget.preset.backgroundArgb;
  late String _category = widget.preset.category;
  bool _inches = false;

  double? _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.'));

  void _save() {
    final f = _inches ? 25.4 : 1.0;
    final w = (_num(_w) ?? 0) * f, h = (_num(_h) ?? 0) * f;
    final p = widget.preset.copyWith(
      name: _name.text.trim(),
      widthMm: w,
      heightMm: h,
      dpi: int.tryParse(_dpi.text) ?? 0,
      headMin: _headMin,
      headMax: _headMax,
      topMargin: _top,
      backgroundArgb: _bg,
      notes: _notes.text.trim(),
      category: _category,
    );
    final errors = p.validate();
    if (errors.isNotEmpty) {
      showSnack(context, errors.join('\n'));
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.preset.builtIn ? 'Edit built-in preset' : 'Preset'), actions: [TextButton(onPressed: _save, child: const Text('Save'))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        Wrap(spacing: 6, children: [
          for (final c in ['passport', 'visa', 'id', 'job', 'student', 'custom'])
            ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
        ]),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('mm')), ButtonSegment(value: true, label: Text('inches'))],
          selected: {_inches},
          onSelectionChanged: (s) => setState(() {
            final toInch = s.first;
            if (toInch != _inches) {
              final f = toInch ? 1 / 25.4 : 25.4;
              _w.text = ((_num(_w) ?? 0) * f).toStringAsFixed(toInch ? 3 : 1);
              _h.text = ((_num(_h) ?? 0) * f).toStringAsFixed(toInch ? 3 : 1);
            }
            _inches = toInch;
          }),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _w, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Width (${_inches ? 'in' : 'mm'})'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _h, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Height (${_inches ? 'in' : 'mm'})'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _dpi, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'DPI'))),
        ]),
        const SizedBox(height: 16),
        Text('Head height (chin to crown) as % of photo height', style: Theme.of(context).textTheme.bodySmall),
        RangeSlider(
          values: RangeValues(_headMin, _headMax),
          min: 0.3,
          max: 0.95,
          divisions: 65,
          labels: RangeLabels('${(_headMin * 100).round()}%', '${(_headMax * 100).round()}%'),
          onChanged: (v) => setState(() {
            _headMin = v.start;
            _headMax = v.end;
          }),
        ),
        LabeledSlider(label: 'Top margin', value: _top, min: 0, max: 0.3, format: (v) => '${(v * 100).round()}%', onChanged: (v) => setState(() => _top = v)),
        const SizedBox(height: 8),
        Text('Required background', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final (name, argb) in backgroundChoices)
            ChoiceChip(
              avatar: CircleAvatar(backgroundColor: Color(argb), radius: 8),
              label: Text(name),
              selected: _bg == argb,
              onSelected: (_) => setState(() => _bg = argb),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _notes, maxLines: 4, decoration: const InputDecoration(labelText: 'Notes / official source to verify')),
      ]),
    );
  }
}
