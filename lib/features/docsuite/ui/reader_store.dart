import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/storage.dart';

class ReaderBookmark {
  final int page;
  final String label;
  const ReaderBookmark(this.page, this.label);
  Map<String, dynamic> toJson() => {'p': page, 'l': label};
  factory ReaderBookmark.fromJson(Map<String, dynamic> j) => ReaderBookmark((j['p'] as num).toInt(), j['l'] as String? ?? '');
}

class ReaderEntry {
  final String key;
  String title;
  int lastPage;
  DateTime opened;
  final List<ReaderBookmark> bookmarks;
  bool encrypted;
  ReaderEntry(this.key, this.title, {this.lastPage = 0, DateTime? opened, List<ReaderBookmark>? bookmarks, this.encrypted = false})
      : opened = opened ?? DateTime.now(),
        bookmarks = bookmarks ?? [];

  Map<String, dynamic> toJson() => {
        't': title,
        'lp': lastPage,
        'o': opened.toIso8601String(),
        'b': [for (final b in bookmarks) b.toJson()],
        'e': encrypted,
      };

  factory ReaderEntry.fromJson(String key, Map<String, dynamic> j) => ReaderEntry(
        key,
        j['t'] as String? ?? 'Document',
        lastPage: (j['lp'] as num?)?.toInt() ?? 0,
        opened: DateTime.tryParse(j['o'] as String? ?? ''),
        bookmarks: [for (final b in (j['b'] as List?) ?? const []) ReaderBookmark.fromJson(b as Map<String, dynamic>)],
        encrypted: j['e'] as bool? ?? false,
      );
}

/// Remembers, per document, the last page read and the reader's bookmarks,
/// and keeps copies of recently read files for the recent-documents
/// switcher. Everything stays in the app's private storage; passwords are
/// never stored (encrypted files ask again).
class ReaderStore {
  static const recentLimit = 10;
  final String root;
  final Map<String, ReaderEntry> _entries = {};
  ReaderStore(this.root);

  static ReaderStore? _instance;
  static Future<ReaderStore> get() async {
    final s = _instance ??= ReaderStore(AppStorage.instance.abs('reader'));
    if (s._entries.isEmpty) await s._load();
    return s;
  }

  File get _file => File(p.join(root, 'state.json'));
  String fileFor(String key) => p.join(root, 'recent', '$key.pdf');

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final m = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      m.forEach((k, v) => _entries[k] = ReaderEntry.fromJson(k, v as Map<String, dynamic>));
    } catch (_) {
      // Damaged state is ignored; reading still works.
    }
  }

  Future<void> save() async {
    await Directory(root).create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({for (final e in _entries.values) e.key: e.toJson()}), flush: true);
    await tmp.rename(_file.path);
  }

  /// A stable key for a file's content (FNV-1a over size and sampled bytes).
  static String keyFor(Uint8List bytes) {
    var h = 0xcbf29ce484222325;
    void mix(int b) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }

    for (final b in utf8.encode('${bytes.length}')) {
      mix(b);
    }
    final step = bytes.length > 1 << 20 ? bytes.length ~/ (1 << 18) : 1;
    for (var i = 0; i < bytes.length; i += step) {
      mix(bytes[i]);
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  ReaderEntry? entry(String key) => _entries[key];

  /// Records that a document was opened and keeps a private copy of it for
  /// the recent list.
  Future<ReaderEntry> opened(Uint8List bytes, String title, {bool encrypted = false}) async {
    final key = keyFor(bytes);
    final e = _entries.putIfAbsent(key, () => ReaderEntry(key, title));
    e
      ..title = title
      ..opened = DateTime.now()
      ..encrypted = encrypted;
    final f = File(fileFor(key));
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    }
    final old = recent().skip(recentLimit).toList();
    for (final o in old) {
      final of = File(fileFor(o.key));
      if (await of.exists()) await of.delete();
      if (o.bookmarks.isEmpty) _entries.remove(o.key);
    }
    await save();
    return e;
  }

  /// Recently read documents whose copy is still available, newest first.
  List<ReaderEntry> recent() {
    final list = _entries.values.where((e) => File(fileFor(e.key)).existsSync()).toList()..sort((a, b) => b.opened.compareTo(a.opened));
    return list;
  }

  Future<void> forget(String key) async {
    _entries.remove(key);
    final f = File(fileFor(key));
    if (await f.exists()) await f.delete();
    await save();
  }
}
