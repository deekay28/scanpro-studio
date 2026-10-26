import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/ids.dart';
import '../../../shared/widgets.dart';
import '../model/edit_state.dart';
import 'editor_controller.dart';

/// Page organiser of the editor: reorder, rotate, delete, insert blank,
/// extract, and document-wide header/footer, watermark and page numbers.
class EditorPagesScreen extends StatefulWidget {
  final PdfEditorController c;
  final Future<void> Function(List<int> slotIndexes) onExtract;
  const EditorPagesScreen({super.key, required this.c, required this.onExtract});

  @override
  State<EditorPagesScreen> createState() => _EditorPagesScreenState();
}

class _EditorPagesScreenState extends State<EditorPagesScreen> {
  final Set<String> _selected = {};

  PdfEditorController get c => widget.c;

  void _apply(EditState s) {
    c.apply(s);
    setState(() {});
  }

  void _rotate(PageSlot s, int d) {
    _apply(c.state.copyWith(slots: [for (final x in c.state.slots) x.id == s.id ? x.rotated(d) : x]));
  }

  Future<void> _delete(List<PageSlot> slots) async {
    if (slots.length >= c.state.slots.length) {
      showSnack(context, 'A PDF needs at least one page.');
      return;
    }
    final items = slots.fold<int>(0, (n, s) => n + c.state.itemsOn(s.id).length);
    final ok = await confirm(
      context,
      slots.length == 1 ? 'Delete this page?' : 'Delete ${slots.length} pages?',
      'The pages are left out of the saved copy. The original file is not changed${items > 0 ? ', and $items item(s) placed on them are removed' : ''}. You can undo this.',
      ok: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    var st = c.state;
    for (final s in slots) {
      st = st.withoutSlot(s.id);
    }
    _selected.clear();
    _apply(st);
  }

  void _insertBlank(int at) {
    final ref = c.state.slots.isEmpty ? null : c.state.slots[(at - 1).clamp(0, c.state.slots.length - 1)];
    final size = ref == null ? const Size(595.28, 841.89) : (c.slotSize ?? const Size(595.28, 841.89));
    final slots = [...c.state.slots]..insert(at, PageSlot(id: 'b${newId()}', blankSize: ref != null && ref.isBlank ? ref.blankSize : size));
    _apply(c.state.copyWith(slots: slots));
  }

  Future<void> _decorations() async {
    final d = await showDialog<Decorations>(context: context, builder: (_) => _DecorationsDialog(initial: c.state.decorations));
    if (d != null) _apply(c.state.copyWith(decorations: d));
  }

  @override
  Widget build(BuildContext context) {
    final slots = c.state.slots;
    final sel = [for (final s in slots) if (_selected.contains(s.id)) s];
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Pages (${slots.length})' : '${_selected.length} selected'),
        actions: [
          IconButton(onPressed: c.history.canUndo ? () => setState(c.undo) : null, icon: const Icon(Icons.undo), tooltip: 'Undo'),
          if (_selected.isNotEmpty) ...[
            IconButton(
              onPressed: () => widget.onExtract([for (var i = 0; i < slots.length; i++) if (_selected.contains(slots[i].id)) i]),
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: 'Extract selected pages',
            ),
            IconButton(onPressed: () => _delete(sel), icon: const Icon(Icons.delete_outline), tooltip: 'Delete selected'),
          ],
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 56,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), children: [
            ActionChip(avatar: const Icon(Icons.note_add_outlined, size: 18), label: const Text('Blank page at end'), onPressed: () => _insertBlank(slots.length)),
            const SizedBox(width: 8),
            ActionChip(avatar: const Icon(Icons.vertical_align_top, size: 18), label: const Text('Header, footer & numbers'), onPressed: _decorations),
            const SizedBox(width: 8),
            ActionChip(avatar: const Icon(Icons.water_drop_outlined, size: 18), label: const Text('Watermark'), onPressed: _decorations),
            if (_selected.isEmpty) ...[
              const SizedBox(width: 8),
              ActionChip(label: const Text('Select all'), onPressed: () => setState(() => _selected.addAll(slots.map((s) => s.id)))),
            ] else ...[
              const SizedBox(width: 8),
              ActionChip(label: const Text('Clear selection'), onPressed: () => setState(_selected.clear)),
            ],
          ]),
        ),
        if (!c.state.decorations.isEmpty)
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline),
            title: Text([
              if (c.state.decorations.header.isNotEmpty) 'Header',
              if (c.state.decorations.footer.isNotEmpty) 'Footer',
              if (c.state.decorations.pageNumbers) 'Page numbers',
              if (c.state.decorations.watermark.isNotEmpty) 'Watermark',
            ].join(', ')),
            subtitle: const Text('Added to every page when saving'),
            trailing: TextButton(onPressed: () => _apply(c.state.copyWith(decorations: const Decorations())), child: const Text('Remove')),
          ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: slots.length,
            onReorder: (from, to) {
              final l = [...c.state.slots];
              final s = l.removeAt(from);
              l.insert(to > from ? to - 1 : to, s);
              _apply(c.state.copyWith(slots: l));
            },
            itemBuilder: (ctx, i) {
              final s = slots[i];
              return Card(
                key: ValueKey(s.id),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: InkWell(
                  onTap: () {
                    c.goTo(i);
                    Navigator.pop(context);
                  },
                  onLongPress: () => setState(() => _selected.contains(s.id) ? _selected.remove(s.id) : _selected.add(s.id)),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(children: [
                      Checkbox(value: _selected.contains(s.id), onChanged: (v) => setState(() => v == true ? _selected.add(s.id) : _selected.remove(s.id))),
                      SizedBox(width: 72, height: 96, child: _Thumb(c: c, slot: s)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Page ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            [
                              s.isBlank ? 'Blank page' : 'Original page ${s.source! + 1}',
                              if (s.rotation != 0) 'rotated ${s.rotation}°',
                              if (c.state.slotHasContentEdits(s)) 'edited',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Row(children: [
                            IconButton(onPressed: () => _rotate(s, 270), icon: const Icon(Icons.rotate_left), tooltip: 'Rotate left'),
                            IconButton(onPressed: () => _rotate(s, 90), icon: const Icon(Icons.rotate_right), tooltip: 'Rotate right'),
                            IconButton(onPressed: () => _insertBlank(i + 1), icon: const Icon(Icons.note_add_outlined), tooltip: 'Insert blank page after'),
                            IconButton(onPressed: () => _delete([s]), icon: const Icon(Icons.delete_outline), tooltip: 'Delete page'),
                          ]),
                        ]),
                      ),
                      ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _Thumb extends StatelessWidget {
  final PdfEditorController c;
  final PageSlot slot;
  const _Thumb({required this.c, required this.slot});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: c.thumbnail(slot),
      builder: (_, snap) {
        final img = snap.data;
        if (img == null) return Container(color: Colors.black12);
        return RotatedBox(
          quarterTurns: slot.rotation ~/ 90,
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
            child: RawImage(image: img, fit: BoxFit.contain),
          ),
        );
      },
    );
  }
}

class _DecorationsDialog extends StatefulWidget {
  final Decorations initial;
  const _DecorationsDialog({required this.initial});
  @override
  State<_DecorationsDialog> createState() => _DecorationsDialogState();
}

class _DecorationsDialogState extends State<_DecorationsDialog> {
  late final _header = TextEditingController(text: widget.initial.header);
  late final _footer = TextEditingController(text: widget.initial.footer);
  late final _wm = TextEditingController(text: widget.initial.watermark);
  late final _fmt = TextEditingController(text: widget.initial.pageNumberFormat);
  late bool _numbers = widget.initial.pageNumbers;
  late double _opacity = widget.initial.watermarkOpacity;
  late int _wmColor = widget.initial.watermarkColor;

  @override
  void dispose() {
    for (final c in [_header, _footer, _wm, _fmt]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Header, footer, page numbers, watermark'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _header, decoration: const InputDecoration(labelText: 'Header (top centre)')),
          TextField(controller: _footer, decoration: const InputDecoration(labelText: 'Footer (bottom centre)')),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Page numbers (bottom right)'), value: _numbers, onChanged: (v) => setState(() => _numbers = v)),
          if (_numbers) TextField(controller: _fmt, decoration: const InputDecoration(labelText: 'Format', helperText: '{n} = page, {total} = page count')),
          const SizedBox(height: 8),
          TextField(controller: _wm, decoration: const InputDecoration(labelText: 'Watermark text', hintText: 'e.g. CONFIDENTIAL')),
          LabeledSlider(label: 'Opacity', value: _opacity, min: 0.05, max: 0.6, onChanged: (v) => setState(() => _opacity = v)),
          Wrap(spacing: 8, children: [
            for (final c in const [0xFFB71C1C, 0xFF616161, 0xFF0D47A1, 0xFF2E7D32])
              ChoiceChip(label: const Text('  '), backgroundColor: Color(c), selectedColor: Color(c), selected: _wmColor == c, onSelected: (_) => setState(() => _wmColor = c)),
          ]),
          const SizedBox(height: 8),
          const Text('These are added as real text on every page of the saved copy; header and page numbers can be selected and searched.', style: TextStyle(fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            Decorations(
              header: _header.text.trim(),
              footer: _footer.text.trim(),
              pageNumbers: _numbers,
              pageNumberFormat: _fmt.text.trim().isEmpty ? 'Page {n} of {total}' : _fmt.text.trim(),
              watermark: _wm.text.trim(),
              watermarkOpacity: _opacity,
              watermarkColor: _wmColor,
            ),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
