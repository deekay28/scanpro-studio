
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets.dart';
import '../../pdf/export_actions.dart';
import '../conversion_service.dart' show validateOutput;
import '../office_conversions.dart' show utf8Bytes;
import '../ooxml/xlsx.dart';
import '../pdf_to_doc.dart' show tableToCsv;
import '../table_extraction.dart' show parseCell;

class _EditSheet {
  String name;
  final List<List<SheetCell>> rows;
  int headerRows;
  final String? note;
  _EditSheet(Sheet s)
      : name = s.name,
        rows = [for (final r in s.rows) [...r]],
        headerRows = s.headerRows,
        note = s.note;

  int get columns => rows.fold(0, (m, r) => r.length > m ? r.length : m);
  Sheet toSheet() => Sheet(name, rows, headerRows: headerRows, note: note);
}

SheetCell _cell(String text, {bool bold = false}) {
  final c = parseCell(text, bold: bold);
  return SheetCell(c.text, number: c.number, date: c.date, bold: c.bold, uncertain: c.uncertain);
}

/// Shows extracted tables before export so columns can be corrected:
/// edit cells, delete or merge columns, split a column at a separator,
/// delete rows and set the header row. Flagged (uncertain) cells are
/// highlighted.
class TableReviewScreen extends StatefulWidget {
  final List<Sheet> sheets;
  final List<String> warnings;
  final String baseName;
  const TableReviewScreen({super.key, required this.sheets, required this.warnings, required this.baseName});

  @override
  State<TableReviewScreen> createState() => _TableReviewScreenState();
}

class _TableReviewScreenState extends State<TableReviewScreen> {
  late final List<_EditSheet> _sheets = [for (final s in widget.sheets) _EditSheet(s)];
  var _index = 0;

  _EditSheet get _s => _sheets[_index];

  void _editCell(int r, int c) async {
    final row = _s.rows[r];
    final current = c < row.length ? row[c].text : '';
    final v = await promptText(context, 'Cell ${_colName(c)}${r + 1}', initial: current, ok: 'Set');
    if (v == null) return;
    setState(() {
      while (row.length <= c) {
        row.add(const SheetCell(''));
      }
      row[c] = _cell(v, bold: r < _s.headerRows);
    });
  }

  void _columnMenu(int c) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Column ${_colName(c)}', style: const TextStyle(fontWeight: FontWeight.w600))),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete column'), onTap: () => Navigator.pop(ctx, 'delete')),
          if (c + 1 < _s.columns)
            ListTile(leading: const Icon(Icons.merge), title: Text('Merge with column ${_colName(c + 1)}'), onTap: () => Navigator.pop(ctx, 'merge')),
          ListTile(leading: const Icon(Icons.call_split), title: const Text('Split column at a separator…'), onTap: () => Navigator.pop(ctx, 'split')),
          ListTile(leading: const Icon(Icons.add), title: const Text('Insert empty column after'), onTap: () => Navigator.pop(ctx, 'insert')),
        ]),
      ),
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'delete':
        setState(() {
          for (final r in _s.rows) {
            if (c < r.length) r.removeAt(c);
          }
        });
      case 'merge':
        setState(() {
          for (var i = 0; i < _s.rows.length; i++) {
            final r = _s.rows[i];
            if (c + 1 >= r.length) continue;
            final joined = [r[c].text, r[c + 1].text].where((t) => t.trim().isNotEmpty).join(' ');
            r[c] = _cell(joined, bold: i < _s.headerRows);
            r.removeAt(c + 1);
          }
        });
      case 'split':
        final sep = await promptText(context, 'Split at', hint: 'Separator, e.g. a space or -', initial: ' ', ok: 'Split');
        if (sep == null || sep.isEmpty) return;
        setState(() {
          for (var i = 0; i < _s.rows.length; i++) {
            final r = _s.rows[i];
            while (r.length <= c) {
              r.add(const SheetCell(''));
            }
            final t = r[c].text;
            final k = t.indexOf(sep);
            final (a, b) = k < 0 ? (t, '') : (t.substring(0, k), t.substring(k + sep.length));
            r[c] = _cell(a.trim(), bold: i < _s.headerRows);
            r.insert(c + 1, _cell(b.trim(), bold: i < _s.headerRows));
          }
        });
      case 'insert':
        setState(() {
          for (final r in _s.rows) {
            while (r.length <= c) {
              r.add(const SheetCell(''));
            }
            r.insert(c + 1, const SheetCell(''));
          }
        });
    }
  }

  void _rowMenu(int r) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Row ${r + 1}', style: const TextStyle(fontWeight: FontWeight.w600))),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete row'), onTap: () => Navigator.pop(ctx, 'delete')),
          ListTile(leading: const Icon(Icons.title), title: Text(r < _s.headerRows ? 'Header ends above this row' : 'Header rows: up to this row'), onTap: () => Navigator.pop(ctx, 'header')),
        ]),
      ),
    );
    if (v == null) return;
    setState(() {
      if (v == 'delete') {
        _s.rows.removeAt(r);
        if (r < _s.headerRows) _s.headerRows--;
      } else {
        _s.headerRows = r < _s.headerRows ? r : r + 1;
        for (var i = 0; i < _s.rows.length; i++) {
          _s.rows[i] = [for (final c in _s.rows[i]) _cell(c.text, bold: i < _s.headerRows)];
        }
      }
    });
  }

  Future<void> _export(String format) async {
    final name = widget.baseName.isEmpty ? 'tables' : widget.baseName;
    final r = await runBusy(context, 'Writing ${format.toUpperCase()}…', (ctl) async {
      if (format == 'xlsx') {
        final bytes = await compute(_xlsx, [for (final s in _sheets) s.toSheet()]);
        await validateOutput('$name.xlsx', bytes);
        return [('$name.xlsx', bytes)];
      }
      final out = <(String, Uint8List)>[];
      for (final s in _sheets) {
        final bytes = utf8Bytes('﻿${tableToCsv([for (final r in s.rows) [for (final c in r) c.text]])}');
        out.add((_sheets.length == 1 ? '$name.csv' : '${name}_${s.name}.csv', bytes));
      }
      return out;
    });
    if (r == null || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(r.length == 1 ? r.first.$1 : '${r.length} files', style: const TextStyle(fontWeight: FontWeight.w600))),
          ListTile(leading: const Icon(Icons.share), title: const Text('Share / open with…'), onTap: () => Navigator.pop(ctx, 'share')),
          ListTile(leading: const Icon(Icons.save_alt), title: const Text('Save to device'), onTap: () => Navigator.pop(ctx, 'save')),
        ]),
      ),
    );
    if (action == 'share') {
      if (r.length == 1) {
        await ExportActions.shareBytes(r.first.$2, r.first.$1, mime: format == 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'text/csv');
      } else {
        final paths = [for (final (n, b) in r) await ExportActions.writeTemp(b, n)];
        await ExportActions.shareFiles(paths);
      }
    } else if (action == 'save') {
      var saved = 0;
      for (final (n, b) in r) {
        if (await ExportActions.saveBytes(b, n) != null) saved++;
      }
      if (saved > 0 && mounted) showSnack(context, saved == 1 ? 'Saved' : 'Saved $saved files');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _s;
    final cols = s.columns;
    final flagged = s.rows.fold<int>(0, (n, r) => n + r.where((c) => c.uncertain).length);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review tables'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Export',
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'xlsx', child: Text('Excel workbook (.xlsx)')),
              PopupMenuItem(value: 'csv', child: Text('CSV (one file per table)')),
            ],
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_sheets.length > 1)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (var i = 0; i < _sheets.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(label: Text(_sheets[i].name), selected: i == _index, onSelected: (_) => setState(() => _index = i)),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Text(
            [
              '${s.rows.length} rows × $cols columns',
              if (s.note != null) s.note!,
              if (flagged > 0) '$flagged flagged cell(s) highlighted',
              'Tap a cell to edit; tap a column letter or row number for more.',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        if (widget.warnings.isNotEmpty)
          ExpansionTile(
            dense: true,
            title: Text('${widget.warnings.length} note(s)', style: const TextStyle(fontSize: 13)),
            children: [for (final w in widget.warnings) ListTile(dense: true, title: Text('• $w', style: const TextStyle(fontSize: 12)))],
          ),
        const Divider(height: 1),
        Expanded(
          child: s.rows.isEmpty
              ? const Center(child: Text('This table is empty.'))
              : InteractiveViewer(
                  constrained: false,
                  minScale: 0.4,
                  maxScale: 2.5,
                  child: Table(
                    defaultColumnWidth: const IntrinsicColumnWidth(),
                    border: TableBorder.all(color: cs.outlineVariant),
                    children: [
                      TableRow(decoration: BoxDecoration(color: cs.surfaceContainerHighest), children: [
                        const SizedBox(width: 36, height: 32),
                        for (var c = 0; c < cols; c++)
                          InkWell(
                            onTap: () => _columnMenu(c),
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 64),
                              height: 32,
                              alignment: Alignment.center,
                              child: Text(_colName(c), style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          ),
                      ]),
                      for (var r = 0; r < s.rows.length; r++)
                        TableRow(
                          decoration: BoxDecoration(color: r < s.headerRows ? cs.primaryContainer.withValues(alpha: 0.4) : null),
                          children: [
                            InkWell(
                              onTap: () => _rowMenu(r),
                              child: Container(
                                width: 36,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                color: cs.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: Text('${r + 1}', style: const TextStyle(fontSize: 12)),
                              ),
                            ),
                            for (var c = 0; c < cols; c++) _cellWidget(r, c),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _cellWidget(int r, int c) {
    final row = _s.rows[r];
    final cell = c < row.length ? row[c] : null;
    final typed = cell != null && (cell.number != null || cell.date != null);
    return InkWell(
      onTap: () => _editCell(r, c),
      child: Container(
        constraints: const BoxConstraints(minWidth: 64, maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        color: cell?.uncertain == true ? Colors.amber.withValues(alpha: 0.35) : null,
        child: Text(
          cell?.text ?? '',
          textAlign: typed ? TextAlign.right : TextAlign.left,
          style: TextStyle(fontSize: 13, fontWeight: cell?.bold == true || r < _s.headerRows ? FontWeight.w600 : FontWeight.normal),
        ),
      ),
    );
  }
}

Uint8List _xlsx(List<Sheet> sheets) => writeXlsx(sheets);

String _colName(int c) {
  var n = c + 1;
  var s = '';
  while (n > 0) {
    final m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}
