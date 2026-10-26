import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../pdf/pdf_viewer_screen.dart';
import '../../pdf_editor/engine/engine_worker.dart';
import '../suite.dart';
import 'page_cache.dart';

/// A PDF being changed by one of the document tools. Every change produces
/// new bytes (the original file is never touched); earlier versions are
/// kept for undo/redo until the tool is closed.
class WorkingDoc extends ChangeNotifier {
  final String title;
  final String? password;
  Uint8List _bytes;
  final List<Uint8List> _undo = [], _redo = [];
  HostSession? _session;
  PageRenderCache? cache;
  int _generation = 0;

  WorkingDoc(Uint8List bytes, this.title, {this.password}) : _bytes = bytes;

  Uint8List get bytes => _bytes;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get changed => _undo.isNotEmpty;
  int get generation => _generation;
  int get pageCount => cache?.pageCount ?? 0;
  HostSession? get session => _session;

  Future<void> load() => _reload();

  Future<void> _reload() async {
    final suite = await DocSuite.get();
    final s = await suite.host.open(_bytes, password: password);
    final c = await PageRenderCache.open(s);
    cache?.dispose();
    _session?.close();
    _session = s;
    cache = c;
    _generation++;
    notifyListeners();
  }

  Future<void> apply(Uint8List next) async {
    _undo.add(_bytes);
    _redo.clear();
    _bytes = next;
    await _reload();
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    _redo.add(_bytes);
    _bytes = _undo.removeLast();
    await _reload();
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    _undo.add(_bytes);
    _bytes = _redo.removeLast();
    await _reload();
  }

  @override
  void dispose() {
    cache?.dispose();
    _session?.close();
    super.dispose();
  }
}

/// Opens a tool's result in the PDF viewer, which offers saving to the
/// library or the device, sharing and printing. The source stays unchanged.
Future<void> showResult(BuildContext context, Uint8List bytes, String title, {String? password, String? parentId}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(bytes: bytes, title: title, password: password, parentId: parentId)));

/// Undo / redo / done buttons for a [WorkingDoc] tool's app bar.
List<Widget> workingDocActions(BuildContext context, WorkingDoc doc, {required String doneLabel, String? parentId}) => [
      IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: doc.canUndo ? doc.undo : null),
      IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: doc.canRedo ? doc.redo : null),
      TextButton(
        onPressed: doc.changed ? () => showResult(context, doc.bytes, '${doc.title} ($doneLabel)', password: doc.password, parentId: parentId) : null,
        child: const Text('Save copy'),
      ),
    ];
