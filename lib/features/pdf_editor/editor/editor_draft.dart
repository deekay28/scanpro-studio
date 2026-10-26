import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/ids.dart';
import '../../../core/storage.dart';
import '../model/edit_state.dart';

/// An editing draft kept in app-private storage so edits survive the app
/// being closed or killed. It holds a copy of the original file (still
/// encrypted if it was), the edit state and inserted image assets.
/// Passwords are never stored: a protected draft asks again on resume.
class EditorDraft {
  final String id;
  final String dir; // absolute
  final String title;
  final String? docId; // library document the draft started from
  final DateTime created;
  DateTime updated;
  final bool encrypted;

  EditorDraft._(this.id, this.dir, this.title, this.docId, this.created, this.updated, this.encrypted);

  static String get _root => AppStorage.instance.abs('editor_drafts');

  File get originalFile => File(p.join(dir, 'original.pdf'));
  File get _stateFile => File(p.join(dir, 'state.json'));
  File get _metaFile => File(p.join(dir, 'meta.json'));
  String get assetsDir => p.join(dir, 'assets');

  static Future<EditorDraft> create(Uint8List original, {required String title, String? docId, required bool encrypted}) async {
    final id = newId();
    final dir = p.join(_root, id);
    await Directory(p.join(dir, 'assets')).create(recursive: true);
    await File(p.join(dir, 'original.pdf')).writeAsBytes(original, flush: true);
    final now = DateTime.now();
    final d = EditorDraft._(id, dir, title, docId, now, now, encrypted);
    await d._writeMeta();
    return d;
  }

  Future<void> _writeMeta() => _metaFile.writeAsString(jsonEncode({
        'id': id,
        'title': title,
        'docId': docId,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'encrypted': encrypted,
      }));

  static Future<List<EditorDraft>> list() async {
    final root = Directory(_root);
    if (!await root.exists()) return const [];
    final out = <EditorDraft>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      try {
        final m = jsonDecode(await File(p.join(e.path, 'meta.json')).readAsString()) as Map<String, dynamic>;
        if (!await File(p.join(e.path, 'original.pdf')).exists()) continue;
        out.add(EditorDraft._(
          m['id'] as String,
          e.path,
          m['title'] as String? ?? 'Document',
          m['docId'] as String?,
          DateTime.tryParse(m['created'] as String? ?? '') ?? DateTime.now(),
          DateTime.tryParse(m['updated'] as String? ?? '') ?? DateTime.now(),
          m['encrypted'] as bool? ?? false,
        ));
      } catch (_) {
        // A damaged draft is skipped; it never blocks the editor.
      }
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  static Future<EditorDraft?> forDocument(String docId) async {
    for (final d in await list()) {
      if (d.docId == docId) return d;
    }
    return null;
  }

  Future<EditState?> loadState() async {
    try {
      if (!await _stateFile.exists()) return null;
      return EditState.fromJson(jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveState(EditState s) async {
    updated = DateTime.now();
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
    await tmp.rename(_stateFile.path);
    await _writeMeta();
  }

  /// Copies an image into the draft and returns its relative asset path.
  Future<String> addAsset(Uint8List bytes, String ext) async {
    final name = 'assets/${newId()}.$ext';
    await File(p.join(dir, name)).writeAsBytes(bytes, flush: true);
    return name;
  }

  Future<void> delete() async {
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
  }
}

/// Debounced autosave of the edit state.
class DraftAutosaver {
  final EditorDraft draft;
  Timer? _timer;
  EditState? _pending;
  DraftAutosaver(this.draft);

  void schedule(EditState s) {
    _pending = s;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final s = _pending;
    _pending = null;
    if (s != null) await draft.saveState(s);
  }
}
