import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite database with explicit, ordered migrations.
///
/// To change the schema: append a new list of statements to [_migrations].
/// Never edit an existing migration that has shipped.
class AppDatabase {
  AppDatabase._(this.db, this.ftsAvailable);

  final Database db;

  /// False if the platform SQLite lacks FTS4; search then falls back to LIKE.
  final bool ftsAvailable;

  static const _migrations = <List<String>>[
    // v1
    [
      '''CREATE TABLE documents(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        opened_at INTEGER,
        folder_id TEXT,
        favourite INTEGER NOT NULL DEFAULT 0,
        deleted_at INTEGER,
        kind TEXT NOT NULL,
        pdf_path TEXT,
        page_count INTEGER NOT NULL DEFAULT 0,
        doc_type TEXT,
        parent_id TEXT
      )''',
      '''CREATE TABLE pages(
        id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        original_path TEXT NOT NULL,
        processed_path TEXT,
        thumb_path TEXT,
        edit_json TEXT,
        ocr_text TEXT,
        ocr_lang TEXT,
        ocr_path TEXT,
        width INTEGER,
        height INTEGER,
        flags TEXT,
        hash TEXT,
        annot_path TEXT,
        overlay_path TEXT,
        created_at INTEGER NOT NULL
      )''',
      'CREATE INDEX idx_pages_doc ON pages(doc_id, position)',
      'CREATE INDEX idx_docs_deleted ON documents(deleted_at)',
      '''CREATE TABLE folders(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE tags(
        doc_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY(doc_id, tag)
      )''',
      '''CREATE TABLE settings(
        key TEXT PRIMARY KEY,
        value TEXT
      )''',
      '''CREATE TABLE scan_sessions(
        id TEXT PRIMARY KEY,
        mode TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE photo_presets(
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      )''',
    ],
  ];

  static int get version => _migrations.length;

  static Future<AppDatabase> open({String? path}) async {
    final dbPath = path ?? p.join(await getDatabasesPath(), 'scanpro.db');
    final db = await openDatabase(
      dbPath,
      version: version,
      onCreate: (db, v) async {
        for (var i = 0; i < v; i++) {
          await _apply(db, i);
        }
      },
      onUpgrade: (db, oldV, newV) async {
        for (var i = oldV; i < newV; i++) {
          await _apply(db, i);
        }
      },
    );
    final fts = await _ensureFts(db);
    return AppDatabase._(db, fts);
  }

  static Future<void> _apply(Database db, int index) async {
    final batch = db.batch();
    for (final s in _migrations[index]) {
      batch.execute(s);
    }
    await batch.commit(noResult: true);
  }

  /// The FTS table lives outside the versioned migrations because it is
  /// optional (depends on the SQLite build) and can be rebuilt any time.
  static Future<bool> _ensureFts(Database db) async {
    try {
      await db.execute('CREATE VIRTUAL TABLE IF NOT EXISTS page_fts USING fts4(doc_id, page_id, content)');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() => db.close();
}
