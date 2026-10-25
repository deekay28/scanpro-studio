import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-private file storage. All paths persisted in the database are
/// relative to [root] so the data survives container path changes.
class AppStorage {
  AppStorage._(this.root, this.cache);

  final Directory root;
  final Directory cache;

  static AppStorage? _instance;
  static AppStorage get instance {
    final i = _instance;
    if (i == null) throw StateError('AppStorage not initialised');
    return i;
  }

  static Future<AppStorage> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    final root = Directory(p.join(docs.path, 'scanpro'));
    final cache = Directory(p.join(tmp.path, 'scanpro_cache'));
    await root.create(recursive: true);
    await cache.create(recursive: true);
    for (final d in ['docs', 'sessions', 'signatures', 'vault', 'presets']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
    _instance = AppStorage._(root, cache);
    return _instance!;
  }

  /// For tests.
  static void initForTest(Directory root, Directory cache) {
    _instance = AppStorage._(root, cache);
  }

  String abs(String relative) => p.isAbsolute(relative) ? relative : p.join(root.path, relative);
  File file(String relative) => File(abs(relative));
  String rel(String absolute) => p.relative(absolute, from: root.path);

  String docDir(String docId) => p.join('docs', docId);
  String sessionDir(String sessionId) => p.join('sessions', sessionId);

  Future<String> ensureDir(String relative) async {
    final d = Directory(abs(relative));
    await d.create(recursive: true);
    return relative;
  }

  /// Unique temp file path in the cache directory.
  String tempPath(String name) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return p.join(cache.path, '${stamp}_$name');
  }

  Future<void> deleteRel(String? relative) async {
    if (relative == null) return;
    try {
      final f = File(abs(relative));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> deleteDirRel(String relative) async {
    try {
      final d = Directory(abs(relative));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<int> usageBytes() async {
    var total = 0;
    try {
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  Future<void> clearCache() async {
    try {
      await for (final e in cache.list()) {
        await e.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// Maps low-level exceptions to messages a user can act on.
String friendlyError(Object e) {
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    if (code == 28) return 'Not enough storage space on the device. Free up space and try again.';
    if (code == 13) return 'Permission denied while accessing the file.';
    if (code == 2) return 'The file no longer exists.';
    return 'File error: ${e.message}';
  }
  if (e is FormatException) return e.message.isEmpty ? 'The file is corrupted or not supported.' : e.message;
  if (e is OutOfMemoryError) return 'The image is too large to process on this device.';
  final s = e.toString();
  if (s.contains('ENOSPC') || s.contains('No space left')) {
    return 'Not enough storage space on the device. Free up space and try again.';
  }
  if (s.toLowerCase().contains('password')) return 'The PDF is password protected or the password is incorrect.';
  return s.replaceFirst('Exception: ', '');
}
