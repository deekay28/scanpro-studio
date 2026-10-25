import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/repository.dart';

/// Local backup/restore as a ZIP archive:
///   manifest.json  – documents, pages, tags, folders, PDF text
///   files/<path>   – originals, processed pages, thumbnails, OCR, annotations, PDFs
/// Restoring always creates new IDs, so it never overwrites existing data.
class BackupService {
  static const format = 'scanpro-backup';
  static const version = 1;

  static Future<String> exportAll(DocumentRepository repo) async {
    final docs = await repo.listDocuments();
    return exportDocuments(repo, docs.map((d) => d.id).toList());
  }

  /// Writes the archive to a temp file and returns its path.
  static Future<String> exportDocuments(DocumentRepository repo, List<String> ids, {String? fileName}) async {
    final out = p.join(repo.storage.cache.path, fileName ?? 'ScanPro_backup_${formatDate(DateTime.now())}_${newId()}.zip');
    final manifestDocs = <Map<String, dynamic>>[];
    final files = <String>{};
    final folderIds = <String>{};
    for (final id in ids) {
      final d = await repo.getDocument(id);
      if (d == null) continue;
      final pages = await repo.getPages(id);
      final row = d.toRow();
      if (d.folderId != null) folderIds.add(d.folderId!);
      if (d.pdfPath != null) files.add(d.pdfPath!);
      for (final pg in pages) {
        for (final f in [pg.originalPath, pg.processedPath, pg.thumbPath, pg.ocrPath, pg.annotPath, pg.overlayPath]) {
          if (f != null && f.isNotEmpty) files.add(f);
        }
      }
      manifestDocs.add({
        'doc': row,
        'tags': d.tags,
        'pages': pages.map((e) => e.toRow()).toList(),
        'pdfText': await repo.pdfText(id),
      });
    }
    final folders = (await repo.listFolders()).where((f) => folderIds.contains(f.id)).map((f) => {'id': f.id, 'name': f.name}).toList();
    final manifest = {
      'format': format,
      'version': version,
      'created': DateTime.now().toIso8601String(),
      'documents': manifestDocs,
      'folders': folders,
    };
    final manifestFile = File(p.join(repo.storage.cache.path, 'manifest_${newId()}.json'));
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);

    final enc = ZipFileEncoder();
    enc.create(out);
    // addFile/close are synchronous in some archive versions and async in
    // others; call them dynamically and await only when a Future is returned.
    Future<void> add(File f, String name) async {
      final r = (enc as dynamic).addFile(f, name);
      if (r is Future) await r;
    }

    await add(manifestFile, 'manifest.json');
    for (final rel in files) {
      final f = repo.storage.file(rel);
      if (await f.exists()) await add(f, 'files/${rel.replaceAll('\\', '/')}');
    }
    final c = (enc as dynamic).close();
    if (c is Future) await c;
    await manifestFile.delete();
    return out;
  }

  /// Restores documents from a backup archive. Returns number restored.
  static Future<int> importArchive(DocumentRepository repo, String zipPath, {void Function(String)? onStatus}) async {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final manifestEntry = archive.files.where((f) => f.name == 'manifest.json').firstOrNull;
      if (manifestEntry == null) throw const FormatException('This ZIP is not a ScanPro backup (manifest.json missing).');
      final manifest = jsonDecode(utf8.decode(manifestEntry.content as List<int>)) as Map<String, dynamic>;
      if (manifest['format'] != format) throw const FormatException('Unsupported backup format.');
      if (((manifest['version'] as num?)?.toInt() ?? 0) > version) {
        throw const FormatException('This backup was made by a newer version of ScanPro Studio. Update the app first.');
      }
      final entries = {for (final f in archive.files) f.name: f};

      // Folders: reuse by name.
      final existingFolders = await repo.listFolders();
      final folderMap = <String, String>{};
      for (final f in (manifest['folders'] as List? ?? const [])) {
        final m = f as Map<String, dynamic>;
        final name = m['name'] as String;
        final match = existingFolders.where((e) => e.name.toLowerCase() == name.toLowerCase()).firstOrNull;
        folderMap[m['id'] as String] = match?.id ?? (await repo.createFolder(name)).id;
      }

      var restored = 0;
      final docs = (manifest['documents'] as List? ?? const []);
      for (var i = 0; i < docs.length; i++) {
        final entry = docs[i] as Map<String, dynamic>;
        final row = Map<String, Object?>.from(entry['doc'] as Map);
        onStatus?.call('Restoring ${i + 1} of ${docs.length}: ${row['title']}');
        final oldId = row['id'] as String;
        final newDocId = newId();
        final oldPrefix = 'docs/$oldId/';
        final newPrefix = 'docs/$newDocId/';
        String? remap(Object? rel) {
          if (rel == null) return null;
          final r = (rel as String).replaceAll('\\', '/');
          final mapped = r.startsWith(oldPrefix) ? newPrefix + r.substring(oldPrefix.length) : '$newPrefix${p.basename(r)}';
          final e = entries['files/$r'];
          if (e != null && e.isFile) {
            final dest = File(repo.storage.abs(mapped));
            dest.parent.createSync(recursive: true);
            final os = OutputFileStream(dest.path);
            e.writeContent(os);
            os.close();
          }
          return mapped;
        }

        row['id'] = newDocId;
        row['pdf_path'] = remap(row['pdf_path']);
        row['folder_id'] = row['folder_id'] == null ? null : folderMap[row['folder_id']];
        row['deleted_at'] = null;
        row['parent_id'] = null;
        final titles = await repo.allTitles();
        var title = row['title'] as String? ?? 'Restored';
        if (titles.any((t) => t.toLowerCase() == title.toLowerCase())) title = '$title (restored)';
        row['title'] = title;
        await repo.db.insert('documents', row);
        for (final t in (entry['tags'] as List? ?? const [])) {
          await repo.db.insert('tags', {'doc_id': newDocId, 'tag': t.toString()});
        }
        for (final pr in (entry['pages'] as List? ?? const [])) {
          final pageRow = Map<String, Object?>.from(pr as Map);
          pageRow['id'] = newId();
          pageRow['doc_id'] = newDocId;
          for (final k in ['original_path', 'processed_path', 'thumb_path', 'ocr_path', 'annot_path', 'overlay_path']) {
            pageRow[k] = remap(pageRow[k]);
          }
          if (pageRow['original_path'] == null) continue;
          await repo.db.insert('pages', pageRow);
        }
        final pdfText = (entry['pdfText'] as List? ?? const []).map((e) => e.toString()).toList();
        if (pdfText.isNotEmpty) await repo.indexPdfText(newDocId, pdfText);
        await repo.reindexDocument(newDocId);
        restored++;
      }
      repo.changed();
      return restored;
    } finally {
      input.close();
    }
  }

  static bool isDocKind(String s) => DocKind.values.any((k) => k.name == s);
}
