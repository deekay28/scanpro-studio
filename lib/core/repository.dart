import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../imaging/processor.dart';
import '../imaging/quality.dart';
import 'database.dart';
import 'ids.dart';
import 'models.dart';
import 'ocr_models.dart';
import 'search_query.dart';
import 'settings.dart';
import 'storage.dart';

/// Single source of truth for documents, pages, folders, tags, OCR index
/// and scan sessions. Widgets listen to it for refreshes.
class DocumentRepository extends ChangeNotifier {
  DocumentRepository(this.adb, this.storage, this.settings);

  final AppDatabase adb;
  final AppStorage storage;
  final SettingsController settings;

  Database get db => adb.db;
  int revision = 0;

  void changed() {
    revision++;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Documents
  // -------------------------------------------------------------------------

  static const _coverSub =
      '(SELECT thumb_path FROM pages p WHERE p.doc_id = d.id ORDER BY position LIMIT 1) AS cover_thumb';

  Future<List<ScanDocument>> listDocuments({
    String? folderId,
    bool favouritesOnly = false,
    bool deleted = false,
    String sort = 'updated',
    String? tag,
    String? kind,
    int? limit,
    bool recentOpened = false,
  }) async {
    final where = <String>[deleted ? 'd.deleted_at IS NOT NULL' : 'd.deleted_at IS NULL'];
    final args = <Object?>[];
    if (folderId != null) {
      where.add('d.folder_id = ?');
      args.add(folderId);
    }
    if (favouritesOnly) where.add('d.favourite = 1');
    if (kind != null) {
      where.add('d.kind = ?');
      args.add(kind);
    }
    if (tag != null) {
      where.add('EXISTS (SELECT 1 FROM tags t WHERE t.doc_id = d.id AND t.tag = ?)');
      args.add(tag);
    }
    if (recentOpened) where.add('d.opened_at IS NOT NULL');
    final order = switch (sort) {
      'name' => 'd.title COLLATE NOCASE ASC',
      'created' => 'd.created_at DESC',
      'opened' => 'd.opened_at DESC',
      'deleted' => 'd.deleted_at DESC',
      _ => 'd.updated_at DESC',
    };
    final rows = await db.rawQuery(
      'SELECT d.*, $_coverSub FROM documents d WHERE ${where.join(' AND ')} ORDER BY $order${limit != null ? ' LIMIT $limit' : ''}',
      args,
    );
    final tags = await _tagsFor(rows.map((r) => r['id'] as String).toList());
    return rows.map((r) => ScanDocument.fromRow(r, tags: tags[r['id']] ?? const [])).toList();
  }

  Future<Map<String, List<String>>> _tagsFor(List<String> ids) async {
    if (ids.isEmpty) return {};
    final out = <String, List<String>>{};
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = await db.query('tags', where: 'doc_id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
      for (final r in rows) {
        (out[r['doc_id'] as String] ??= []).add(r['tag'] as String);
      }
    }
    return out;
  }

  Future<ScanDocument?> getDocument(String id) async {
    final rows = await db.rawQuery('SELECT d.*, $_coverSub FROM documents d WHERE d.id = ?', [id]);
    if (rows.isEmpty) return null;
    final tags = await _tagsFor([id]);
    return ScanDocument.fromRow(rows.first, tags: tags[id] ?? const []);
  }

  Future<List<String>> allTitles() async {
    final rows = await db.query('documents', columns: ['title'], where: 'deleted_at IS NULL');
    return rows.map((r) => r['title'] as String).toList();
  }

  Future<ScanDocument> createDocument({
    required String title,
    DocKind kind = DocKind.scan,
    String? pdfPath,
    String? parentId,
    String? folderId,
    String? docType,
    int pageCount = 0,
  }) async {
    final now = DateTime.now();
    final doc = ScanDocument(
      id: newId(),
      title: title,
      createdAt: now,
      updatedAt: now,
      kind: kind,
      pdfPath: pdfPath,
      parentId: parentId,
      folderId: folderId,
      docType: docType,
      pageCount: pageCount,
    );
    await db.insert('documents', doc.toRow());
    await storage.ensureDir(storage.docDir(doc.id));
    changed();
    return doc;
  }

  Future<void> _touch(String docId) async {
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM pages WHERE doc_id = ?', [docId])) ?? 0;
    final doc = await getDocument(docId);
    final pc = doc != null && doc.isPdf ? doc.pageCount : count;
    await db.update('documents', {'updated_at': DateTime.now().millisecondsSinceEpoch, 'page_count': pc},
        where: 'id = ?', whereArgs: [docId]);
  }

  Future<void> rename(String id, String title) async {
    await db.update('documents', {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    changed();
  }

  Future<void> setDocType(String id, String? type) async {
    await db.update('documents', {'doc_type': type}, where: 'id = ?', whereArgs: [id]);
    changed();
  }

  Future<void> setFavourite(String id, bool fav) async {
    await db.update('documents', {'favourite': fav ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    changed();
  }

  Future<void> moveToFolder(String id, String? folderId) async {
    await db.update('documents', {'folder_id': folderId}, where: 'id = ?', whereArgs: [id]);
    changed();
  }

  Future<void> markOpened(String id) async {
    await db.update('documents', {'opened_at': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setTags(String id, List<String> tags) async {
    await db.transaction((txn) async {
      await txn.delete('tags', where: 'doc_id = ?', whereArgs: [id]);
      for (final t in tags.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet()) {
        await txn.insert('tags', {'doc_id': id, 'tag': t});
      }
    });
    changed();
  }

  Future<List<String>> allTags() async {
    final rows = await db.rawQuery(
        'SELECT DISTINCT t.tag FROM tags t JOIN documents d ON d.id = t.doc_id WHERE d.deleted_at IS NULL ORDER BY t.tag COLLATE NOCASE');
    return rows.map((r) => r['tag'] as String).toList();
  }

  Future<void> softDelete(String id) async {
    await db.update('documents', {'deleted_at': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);
    await _unindexDoc(id);
    changed();
  }

  Future<void> restore(String id) async {
    await db.update('documents', {'deleted_at': null}, where: 'id = ?', whereArgs: [id]);
    await _reindexDoc(id);
    changed();
  }

  /// Permanently removes a document and its files. Note: flash storage does
  /// not guarantee secure erasure; files are deleted, not shredded.
  Future<void> purge(String id) async {
    await db.transaction((txn) async {
      await txn.delete('pages', where: 'doc_id = ?', whereArgs: [id]);
      await txn.delete('tags', where: 'doc_id = ?', whereArgs: [id]);
      await txn.delete('documents', where: 'id = ?', whereArgs: [id]);
      await txn.delete('settings', where: 'key = ?', whereArgs: ['pdftext:$id']);
    });
    await _unindexDoc(id);
    await storage.deleteDirRel(storage.docDir(id));
    changed();
  }

  Future<int> emptyTrash() async {
    final docs = await listDocuments(deleted: true);
    for (final d in docs) {
      await purge(d.id);
    }
    return docs.length;
  }

  Future<int> purgeExpiredTrash() async {
    final days = settings.trashRetentionDays;
    final cutoff = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    final rows = await db.query('documents', columns: ['id'], where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
    for (final r in rows) {
      await purge(r['id'] as String);
    }
    return rows.length;
  }

  /// Finds existing documents whose first page looks identical to [hash].
  Future<List<ScanDocument>> findDuplicatesByHash(String hash, {String? excludeDocId}) async {
    final rows = await db.rawQuery(
        'SELECT p.doc_id, p.hash FROM pages p JOIN documents d ON d.id = p.doc_id WHERE d.deleted_at IS NULL AND p.hash IS NOT NULL');
    final ids = <String>{};
    for (final r in rows) {
      final id = r['doc_id'] as String;
      if (id == excludeDocId) continue;
      if (isDuplicateHash(hash, r['hash'] as String)) ids.add(id);
    }
    final out = <ScanDocument>[];
    for (final id in ids) {
      final d = await getDocument(id);
      if (d != null) out.add(d);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Pages
  // -------------------------------------------------------------------------

  Future<List<DocPage>> getPages(String docId) async {
    final rows = await db.query('pages', where: 'doc_id = ?', whereArgs: [docId], orderBy: 'position ASC');
    return rows.map(DocPage.fromRow).toList();
  }

  Future<DocPage?> getPage(String id) async {
    final rows = await db.query('pages', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : DocPage.fromRow(rows.first);
  }

  String _ext(String path) {
    final e = p.extension(path).toLowerCase();
    return const ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif', '.tif', '.tiff'].contains(e) ? e : '.jpg';
  }

  /// Adds an image as a new page. The source file is copied unchanged into
  /// app storage as the preserved original; a processed copy is rendered.
  Future<DocPage> addPage(
    String docId,
    String sourcePath, {
    PageEdit? edit,
    ImageAnalysis? analysis,
    bool documentExpected = true,
    String? sharedOriginalRel,
    int? position,
  }) async {
    final pageId = newId();
    final dir = storage.docDir(docId);
    await storage.ensureDir(p.join(dir, 'orig'));
    await storage.ensureDir(p.join(dir, 'proc'));
    await storage.ensureDir(p.join(dir, 'thumb'));
    String origRel;
    if (sharedOriginalRel != null) {
      origRel = sharedOriginalRel;
    } else {
      origRel = p.join(dir, 'orig', '$pageId${_ext(sourcePath)}');
      await File(sourcePath).copy(storage.abs(origRel));
    }
    try {
      final a = analysis ?? await analyzeImage(storage.abs(origRel), documentExpected: documentExpected);
      final flags = [...a.flags];
      final existing = await getPages(docId);
      if (existing.any((e) => e.hash != null && isDuplicateHash(e.hash!, a.hash))) {
        flags.add(QualityFlag.duplicate);
      }
      final e = edit ??
          PageEdit(
            corners: documentExpected && a.detectionScore >= 0.5 ? a.corners : null,
            preset: documentExpected ? settings.defaultPreset : FilterPreset.original,
          );
      final out = await _render(docId, pageId, origRel, e);
      final page = DocPage(
        id: pageId,
        docId: docId,
        position: position ?? existing.length,
        originalPath: origRel,
        processedPath: out.$1,
        thumbPath: out.$2,
        edit: e,
        width: out.$3,
        height: out.$4,
        flags: flags,
        hash: a.hash,
        createdAt: DateTime.now(),
      );
      if (position != null) {
        await db.rawUpdate('UPDATE pages SET position = position + 1 WHERE doc_id = ? AND position >= ?', [docId, position]);
      }
      await db.insert('pages', page.toRow());
      await _touch(docId);
      changed();
      return page;
    } catch (e) {
      if (sharedOriginalRel == null) await storage.deleteRel(origRel);
      rethrow;
    }
  }

  /// Renders processed + thumbnail; returns (procRel, thumbRel, w, h).
  Future<(String, String, int, int)> _render(String docId, String pageId, String origRel, PageEdit e) async {
    final dir = storage.docDir(docId);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final procRel = p.join(dir, 'proc', '${pageId}_$stamp.jpg');
    final thumbRel = p.join(dir, 'thumb', '${pageId}_$stamp.jpg');
    final r = await processPage(ProcessInput(
      originalPath: storage.abs(origRel),
      outPath: storage.abs(procRel),
      thumbPath: storage.abs(thumbRel),
      edit: e.toJson(),
      maxDim: settings.processingMaxDim,
      quality: settings.jpegQuality,
    ));
    return (procRel, thumbRel, r.width, r.height);
  }

  /// Re-renders a page from its original with a new recipe. OCR data is
  /// invalidated because the image changed.
  Future<DocPage> updatePageEdit(DocPage page, PageEdit edit) async {
    final out = await _render(page.docId, page.id, page.originalPath, edit);
    await storage.deleteRel(page.processedPath);
    await storage.deleteRel(page.thumbPath);
    await storage.deleteRel(page.ocrPath);
    await db.update(
      'pages',
      {
        'processed_path': out.$1,
        'thumb_path': out.$2,
        'edit_json': edit.encode(),
        'width': out.$3,
        'height': out.$4,
        'ocr_text': null,
        'ocr_path': null,
        'ocr_lang': null,
      },
      where: 'id = ?',
      whereArgs: [page.id],
    );
    await _unindexPage(page.id);
    await _touch(page.docId);
    changed();
    return (await getPage(page.id))!;
  }

  Future<void> reorderPages(String docId, List<String> orderedIds) async {
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update('pages', {'position': i}, where: 'id = ? AND doc_id = ?', whereArgs: [orderedIds[i], docId]);
      }
    });
    await _touch(docId);
    changed();
  }

  Future<void> deletePage(DocPage page) async {
    await db.delete('pages', where: 'id = ?', whereArgs: [page.id]);
    final shared = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM pages WHERE original_path = ?', [page.originalPath])) ?? 0;
    if (shared == 0) await storage.deleteRel(page.originalPath);
    for (final f in [page.processedPath, page.thumbPath, page.ocrPath, page.annotPath, page.overlayPath]) {
      await storage.deleteRel(f);
    }
    await _unindexPage(page.id);
    final rest = await getPages(page.docId);
    await reorderPages(page.docId, rest.map((e) => e.id).toList());
  }

  Future<String> _copyRel(String? rel, String docId, String sub, String newName) async {
    if (rel == null) return '';
    final dst = p.join(storage.docDir(docId), sub, newName);
    await storage.ensureDir(p.dirname(dst));
    await storage.file(rel).copy(storage.abs(dst));
    return dst;
  }

  /// Copies a page (with its own copy of all files) into [targetDocId].
  Future<DocPage> copyPageTo(DocPage page, String targetDocId, {int? position}) async {
    final id = newId();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final orig = await _copyRel(page.originalPath, targetDocId, 'orig', '$id${p.extension(page.originalPath)}');
    final proc = page.processedPath == null ? null : await _copyRel(page.processedPath, targetDocId, 'proc', '${id}_$stamp.jpg');
    final thumb = page.thumbPath == null ? null : await _copyRel(page.thumbPath, targetDocId, 'thumb', '${id}_$stamp.jpg');
    final ocr = page.ocrPath == null ? null : await _copyRel(page.ocrPath, targetDocId, 'ocr', '$id.json');
    final annot = page.annotPath == null ? null : await _copyRel(page.annotPath, targetDocId, 'annot', '$id.json');
    final overlay = page.overlayPath == null ? null : await _copyRel(page.overlayPath, targetDocId, 'annot', '${id}_$stamp.png');
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM pages WHERE doc_id = ?', [targetDocId])) ?? 0;
    final pos = position ?? count;
    if (position != null) {
      await db.rawUpdate('UPDATE pages SET position = position + 1 WHERE doc_id = ? AND position >= ?', [targetDocId, pos]);
    }
    final copy = DocPage(
      id: id,
      docId: targetDocId,
      position: pos,
      originalPath: orig,
      processedPath: proc,
      thumbPath: thumb,
      edit: page.edit,
      ocrText: page.ocrText,
      ocrLang: page.ocrLang,
      ocrPath: ocr,
      width: page.width,
      height: page.height,
      flags: page.flags.where((f) => f != QualityFlag.duplicate).toList(),
      hash: page.hash,
      annotPath: annot,
      overlayPath: overlay,
      createdAt: DateTime.now(),
    );
    await db.insert('pages', copy.toRow());
    if (copy.ocrText != null) await _indexPage(targetDocId, copy.id, copy.ocrText!);
    await _touch(targetDocId);
    changed();
    return copy;
  }

  Future<DocPage> duplicatePage(DocPage page) => copyPageTo(page, page.docId, position: page.position + 1);

  /// A full, independent copy of a document (its PDF file, pages, OCR,
  /// annotations, tags and search text) in the same folder.
  Future<ScanDocument> duplicateDocument(String id) async {
    final d = await getDocument(id);
    if (d == null) throw StateError('Document not found');
    final copy = await createDocument(
      title: '${d.title} (copy)',
      kind: d.kind,
      folderId: d.folderId,
      docType: d.docType,
      parentId: d.parentId,
      pageCount: d.pdfPath != null ? d.pageCount : 0,
    );
    if (d.pdfPath != null) {
      final rel = await _copyRel(d.pdfPath, copy.id, '', p.basename(d.pdfPath!));
      await db.update('documents', {'pdf_path': rel}, where: 'id = ?', whereArgs: [copy.id]);
      final texts = await pdfText(id);
      if (texts.isNotEmpty) await indexPdfText(copy.id, texts);
    }
    for (final page in await getPages(id)) {
      await copyPageTo(page, copy.id);
    }
    if (d.tags.isNotEmpty) await setTags(copy.id, d.tags);
    changed();
    return (await getDocument(copy.id))!;
  }

  /// Storage used by a document's files (PDF, page images, OCR data).
  Future<int> documentSize(String id) async {
    final dir = Directory(storage.abs(storage.docDir(id)));
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> rotatePage(DocPage page, int delta) =>
      updatePageEdit(page, page.edit.copyWith(rotation: (page.edit.rotation + delta + 360) % 360));

  Future<void> setPageAnnotations(DocPage page, {String? annotJson, String? overlayAbsPath}) async {
    String? annotRel = page.annotPath, overlayRel;
    if (annotJson != null) {
      annotRel = p.join(storage.docDir(page.docId), 'annot', '${page.id}.json');
      await storage.ensureDir(p.dirname(annotRel));
      await storage.file(annotRel).writeAsString(annotJson, flush: true);
    }
    await storage.deleteRel(page.overlayPath);
    if (overlayAbsPath != null) {
      overlayRel = p.join(storage.docDir(page.docId), 'annot', '${page.id}_${DateTime.now().millisecondsSinceEpoch}.png');
      await File(overlayAbsPath).copy(storage.abs(overlayRel));
    }
    await db.update('pages', {'annot_path': annotRel, 'overlay_path': overlayRel}, where: 'id = ?', whereArgs: [page.id]);
    await _touch(page.docId);
    changed();
  }

  Future<void> clearPageFlag(DocPage page, String flag) async {
    await db.update('pages', {'flags': page.flags.where((f) => f != flag).join(',')}, where: 'id = ?', whereArgs: [page.id]);
    changed();
  }

  // -------------------------------------------------------------------------
  // OCR + full-text index
  // -------------------------------------------------------------------------

  Future<OcrPageResult?> loadOcr(DocPage page) async {
    if (page.ocrPath == null) return null;
    try {
      return OcrPageResult.decode(await storage.file(page.ocrPath!).readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> saveOcr(DocPage page, OcrPageResult result) async {
    final rel = p.join(storage.docDir(page.docId), 'ocr', '${page.id}.json');
    await storage.ensureDir(p.dirname(rel));
    await storage.file(rel).writeAsString(result.encode(), flush: true);
    final text = result.text;
    await db.update('pages', {'ocr_text': text, 'ocr_lang': result.script, 'ocr_path': rel}, where: 'id = ?', whereArgs: [page.id]);
    await _unindexPage(page.id);
    await _indexPage(page.docId, page.id, text);
    changed();
  }

  /// Stores extracted text of page [index] of an imported PDF.
  Future<void> indexPdfText(String docId, List<String> pageTexts) async {
    await _unindexDoc(docId);
    for (var i = 0; i < pageTexts.length; i++) {
      if (pageTexts[i].trim().isEmpty) continue;
      await _indexPage(docId, '$docId#$i', pageTexts[i]);
    }
    await db.insert('settings', {'key': 'pdftext:$docId', 'value': jsonEncode(pageTexts)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<String>> pdfText(String docId) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: ['pdftext:$docId']);
    if (rows.isEmpty) return const [];
    try {
      return (jsonDecode(rows.first['value'] as String) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _indexPage(String docId, String pageId, String text) async {
    if (!adb.ftsAvailable || !settings.searchIndexing || text.trim().isEmpty) return;
    await db.insert('page_fts', {'doc_id': docId, 'page_id': pageId, 'content': text});
  }

  Future<void> _unindexPage(String pageId) async {
    if (!adb.ftsAvailable) return;
    await db.delete('page_fts', where: 'page_id = ?', whereArgs: [pageId]);
  }

  Future<void> _unindexDoc(String docId) async {
    if (!adb.ftsAvailable) return;
    await db.delete('page_fts', where: 'doc_id = ?', whereArgs: [docId]);
  }

  Future<void> _reindexDoc(String docId) async {
    await _unindexDoc(docId);
    for (final pg in await getPages(docId)) {
      if (pg.ocrText != null) await _indexPage(docId, pg.id, pg.ocrText!);
    }
    final pdf = await pdfText(docId);
    for (var i = 0; i < pdf.length; i++) {
      if (pdf[i].trim().isNotEmpty) await _indexPage(docId, '$docId#$i', pdf[i]);
    }
  }

  Future<void> reindexDocument(String docId) => _reindexDoc(docId);

  Future<void> clearIndex() async {
    if (!adb.ftsAvailable) return;
    await db.delete('page_fts');
    changed();
  }

  Future<void> rebuildIndex() async {
    await clearIndex();
    if (!settings.searchIndexing) return;
    for (final d in await listDocuments()) {
      await _reindexDoc(d.id);
    }
    changed();
  }

  Future<int> indexedPageCount() async {
    if (!adb.ftsAvailable) return 0;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM page_fts')) ?? 0;
  }

  /// Searches titles, tags and OCR/PDF text. Returns at most one hit per
  /// document (the best page match), title matches first.
  Future<List<SearchHit>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final hits = <String, SearchHit>{};
    final terms = likeTerms(q);
    final likeArg = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
    final titleRows = await db.rawQuery(
      'SELECT d.*, $_coverSub FROM documents d WHERE d.deleted_at IS NULL AND (d.title LIKE ? OR EXISTS (SELECT 1 FROM tags t WHERE t.doc_id = d.id AND t.tag LIKE ?)) ORDER BY d.updated_at DESC LIMIT 100',
      [likeArg, likeArg],
    );
    for (final r in titleRows) {
      final d = ScanDocument.fromRow(r);
      hits[d.id] = SearchHit(d, titleMatch: true);
    }
    final textHits = <(String, String, String)>[]; // docId, pageId, snippet
    final fts = buildFtsQuery(q);
    var usedFts = false;
    if (adb.ftsAvailable && fts != null && settings.searchIndexing) {
      try {
        final rows = await db.rawQuery(
          "SELECT doc_id, page_id, snippet(page_fts, '[', ']', '…', 2, 14) AS snip FROM page_fts WHERE content MATCH ? LIMIT 300",
          [fts],
        );
        for (final r in rows) {
          textHits.add((r['doc_id'] as String, r['page_id'] as String, (r['snip'] as String?) ?? ''));
        }
        usedFts = true;
      } catch (_) {
        usedFts = false;
      }
    }
    if (!usedFts && terms.isNotEmpty) {
      final conds = terms.map((_) => 'ocr_text LIKE ?').join(' AND ');
      final rows = await db.rawQuery(
        'SELECT doc_id, id, ocr_text FROM pages WHERE ocr_text IS NOT NULL AND $conds LIMIT 300',
        terms.map((t) => '%$t%').toList(),
      );
      for (final r in rows) {
        textHits.add((r['doc_id'] as String, r['id'] as String, makeSnippet(r['ocr_text'] as String, terms)));
      }
    }
    for (final (docId, pageId, snip) in textHits) {
      final existing = hits[docId];
      if (existing != null && existing.snippet != null) continue;
      final doc = existing?.document ?? await getDocument(docId);
      if (doc == null || doc.isDeleted) continue;
      int? index;
      if (pageId.contains('#')) {
        index = int.tryParse(pageId.split('#').last);
      } else {
        final pr = await db.query('pages', columns: ['position'], where: 'id = ?', whereArgs: [pageId]);
        if (pr.isNotEmpty) index = (pr.first['position'] as num).toInt();
      }
      hits[docId] = SearchHit(doc, pageId: pageId, pageIndex: index, snippet: snip, titleMatch: existing?.titleMatch ?? false);
    }
    final list = hits.values.toList()
      ..sort((a, b) {
        if (a.titleMatch != b.titleMatch) return a.titleMatch ? -1 : 1;
        return b.document.updatedAt.compareTo(a.document.updatedAt);
      });
    return list;
  }

  // -------------------------------------------------------------------------
  // Folders
  // -------------------------------------------------------------------------

  Future<List<Folder>> listFolders() async {
    final rows = await db.query('folders', orderBy: 'name COLLATE NOCASE');
    return rows
        .map((r) => Folder(r['id'] as String, r['name'] as String, DateTime.fromMillisecondsSinceEpoch((r['created_at'] as num).toInt())))
        .toList();
  }

  Future<Folder> createFolder(String name) async {
    final f = Folder(newId(), name.trim(), DateTime.now());
    await db.insert('folders', {'id': f.id, 'name': f.name, 'created_at': f.createdAt.millisecondsSinceEpoch});
    changed();
    return f;
  }

  Future<void> renameFolder(String id, String name) async {
    await db.update('folders', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    changed();
  }

  Future<void> deleteFolder(String id) async {
    await db.update('documents', {'folder_id': null}, where: 'folder_id = ?', whereArgs: [id]);
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
    changed();
  }

  // -------------------------------------------------------------------------
  // Scan sessions (crash recovery)
  // -------------------------------------------------------------------------

  Future<void> saveSession(ScanSessionData s) async {
    await db.insert(
      'scan_sessions',
      {'id': s.id, 'mode': s.mode, 'data': jsonEncode(s.toJson()), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ScanSessionData>> unfinishedSessions() async {
    final rows = await db.query('scan_sessions', orderBy: 'updated_at DESC');
    final out = <ScanSessionData>[];
    for (final r in rows) {
      try {
        final s = ScanSessionData.fromRow(r);
        final alive = s.items.where((i) => storage.file(i.path).existsSync()).toList();
        if (alive.isEmpty) {
          await discardSession(s.id);
        } else {
          out.add(s.copyWith(items: alive));
        }
      } catch (_) {
        await db.delete('scan_sessions', where: 'id = ?', whereArgs: [r['id']]);
      }
    }
    return out;
  }

  Future<void> discardSession(String id) async {
    await db.delete('scan_sessions', where: 'id = ?', whereArgs: [id]);
    await storage.deleteDirRel(storage.sessionDir(id));
    changed();
  }

  /// Finishes a session (rows removed; captured files deleted after they
  /// were copied into the document).
  Future<void> completeSession(String id) => discardSession(id);
}
