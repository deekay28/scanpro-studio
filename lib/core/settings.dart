import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// User preferences persisted in the `settings` table.
class SettingsController extends ChangeNotifier {
  SettingsController(this._db);

  final Database _db;
  final Map<String, String> _values = {};

  Future<void> load() async {
    final rows = await _db.query('settings');
    _values
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r['key'] as String, (r['value'] as String?) ?? '')));
    notifyListeners();
  }

  String? raw(String key) => _values[key];

  Future<void> setRaw(String key, String value) async {
    _values[key] = value;
    await _db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  bool _bool(String k, bool d) => _values[k] == null ? d : _values[k] == '1';
  int _int(String k, int d) => int.tryParse(_values[k] ?? '') ?? d;
  Future<void> _setBool(String k, bool v) => setRaw(k, v ? '1' : '0');

  ThemeMode get themeMode => switch (_values['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  Future<void> setThemeMode(ThemeMode m) => setRaw('theme', m.name);

  FilterPreset get defaultPreset =>
      FilterPreset.values.firstWhere((p) => p.name == _values['defaultPreset'], orElse: () => FilterPreset.smartAuto);
  Future<void> setDefaultPreset(FilterPreset p) => setRaw('defaultPreset', p.name);

  /// Longest side, in pixels, of processed pages (originals are untouched).
  int get processingMaxDim => _int('maxDim', 2800);
  Future<void> setProcessingMaxDim(int v) => setRaw('maxDim', '$v');

  String get defaultPageSize => _values['pageSize'] ?? 'a4';
  Future<void> setDefaultPageSize(String id) => setRaw('pageSize', id);

  /// 'latin' or 'devanagari'.
  String get ocrScript => _values['ocrScript'] ?? 'latin';
  Future<void> setOcrScript(String s) => setRaw('ocrScript', s);

  bool get autoOcr => _bool('autoOcr', false);
  Future<void> setAutoOcr(bool v) => _setBool('autoOcr', v);

  bool get searchIndexing => _bool('indexing', true);
  Future<void> setSearchIndexing(bool v) => _setBool('indexing', v);

  int get trashRetentionDays => _int('trashDays', 30);
  Future<void> setTrashRetentionDays(int v) => setRaw('trashDays', '$v');

  bool get appLock => _bool('appLock', false);
  Future<void> setAppLock(bool v) => _setBool('appLock', v);

  bool get qualityWarnings => _bool('qualityWarnings', true);
  Future<void> setQualityWarnings(bool v) => _setBool('qualityWarnings', v);

  bool get autoCapture => _bool('autoCapture', true);
  Future<void> setAutoCapture(bool v) => _setBool('autoCapture', v);

  bool get gridView => _bool('gridView', true);
  Future<void> setGridView(bool v) => _setBool('gridView', v);

  bool get onboarded => _bool('onboarded', false);
  Future<void> setOnboarded(bool v) => _setBool('onboarded', v);

  /// JPEG quality for processed pages.
  int get jpegQuality => _int('jpegQuality', 90);
  Future<void> setJpegQuality(int v) => setRaw('jpegQuality', '$v');
}
