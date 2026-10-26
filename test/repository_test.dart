import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/core/database.dart';
import 'package:scanpro_studio/core/models.dart';
import 'package:scanpro_studio/core/ocr_models.dart';
import 'package:scanpro_studio/core/repository.dart';
import 'package:scanpro_studio/core/settings.dart';
import 'package:scanpro_studio/core/storage.dart';
import 'package:scanpro_studio/features/backup/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Writes a test "document" photo: dark background, light page, text bars.
Uint8List docPhoto({int seed = 0}) {
  final im = img.Image(width: 800, height: 600);
  img.fill(im, color: img.ColorRgb8(40, 40, 45));
  img.fillRect(im, x1: 120, y1: 60, x2: 680, y2: 560, color: img.ColorRgb8(225, 222, 215));
  for (var i = 0; i < 8; i++) {
    final y = 110 + i * 50;
    img.fillRect(im, x1: 170, y1: y, x2: 420 + ((i * 37 + seed * 53) % 220), y2: y + 8, color: img.ColorRgb8(30, 30, 30));
  }
  if (seed > 0) img.fillCircle(im, x: 200 + seed * 60, y: 480, radius: 30, color: img.ColorRgb8(200, 30, 30));
  return img.encodeJpg(im, quality: 92);
}

OcrPageResult ocr(String text) => OcrPageResult(
      script: 'latin',
      imageWidth: 100,
      imageHeight: 100,
      createdAt: DateTime.now(),
      lines: [OcrLine(text: text, left: 1, top: 1, right: 90, bottom: 10)],
    );

void main() {
  late Directory dir;
  late AppDatabase adb;
  late DocumentRepository repo;
  late String dbPath;

  Future<DocumentRepository> openRepo() async {
    adb = await AppDatabase.open(path: dbPath);
    final settings = SettingsController(adb.db);
    await settings.load();
    return DocumentRepository(adb, AppStorage.instance, settings);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('scanpro_repo');
    final root = Directory('${dir.path}/root')..createSync();
    for (final d in ['docs', 'sessions', 'vault']) {
      Directory('${root.path}/$d').createSync();
    }
    AppStorage.initForTest(root, Directory('${dir.path}/cache')..createSync());
    dbPath = '${dir.path}/test.db';
    repo = await openRepo();
  });

  tearDown(() async {
    await adb.close();
    await dir.delete(recursive: true);
  });

  File source(String name, {int seed = 0}) => File('${dir.path}/$name')..writeAsBytesSync(docPhoto(seed: seed));

  test('FTS is available in the test SQLite', () {
    expect(adb.ftsAvailable, isTrue);
  });

  test('ACCEPTANCE 1: original scan stays recoverable after enhancement', () async {
    final src = source('a.jpg');
    final originalBytes = src.readAsBytesSync();
    final doc = await repo.createDocument(title: 'Contract');
    var page = await repo.addPage(doc.id, src.path, edit: const PageEdit(preset: FilterPreset.blackWhite));
    final origFile = repo.storage.file(page.originalPath);
    expect(origFile.readAsBytesSync(), originalBytes, reason: 'original stored byte-for-byte');
    final firstProcessed = page.processedPath!;
    expect(repo.storage.file(firstProcessed).existsSync(), isTrue);

    page = await repo.updatePageEdit(page, const PageEdit(preset: FilterPreset.grayscale, contrast: 0.3));
    expect(origFile.readAsBytesSync(), originalBytes, reason: 'original untouched by re-edit');
    expect(repo.storage.file(firstProcessed).existsSync(), isFalse, reason: 'stale processed file removed');

    page = await repo.updatePageEdit(page, const PageEdit()); // revert all
    expect(page.edit.isIdentity, isTrue);
    final processed = img.decodeJpg(repo.storage.file(page.processedPath!).readAsBytesSync())!;
    expect(processed.width, 800);
    expect(processed.height, 600);
  });

  test('automatic edge detection crops the page on import', () async {
    final doc = await repo.createDocument(title: 'Auto crop');
    final page = await repo.addPage(doc.id, source('b.jpg').path);
    expect(page.edit.corners, isNotNull);
    // Page in the photo is 560 x 500 px; processed output should be close.
    expect(page.width, closeTo(560, 25));
    expect(page.height, closeTo(500, 25));
  });

  test('ACCEPTANCE 2: OCR search finds a known word; index follows edits and deletes', () async {
    final doc = await repo.createDocument(title: 'Utility');
    var page = await repo.addPage(doc.id, source('c.jpg').path);
    await repo.saveOcr(page, ocr('Electricity bill for Andheri Mumbai March'));
    var hits = await repo.search('electricity');
    expect(hits.length, 1);
    expect(hits.first.document.id, doc.id);
    expect(hits.first.pageIndex, 0);
    expect(hits.first.snippet, contains('Electricity'));
    expect((await repo.search('Mumb')).length, 1, reason: 'prefix search');
    expect((await repo.search('"bill for andheri"')).length, 1, reason: 'phrase search');
    expect(await repo.search('gas'), isEmpty);

    await repo.softDelete(doc.id);
    expect(await repo.search('electricity'), isEmpty, reason: 'deleted docs are not searchable');
    await repo.restore(doc.id);
    expect((await repo.search('electricity')).length, 1, reason: 'restored docs are re-indexed');

    page = (await repo.getPages(doc.id)).first;
    await repo.updatePageEdit(page, const PageEdit(preset: FilterPreset.grayscale));
    expect(await repo.search('electricity'), isEmpty, reason: 'stale OCR removed after image edit');

    page = (await repo.getPages(doc.id)).first;
    await repo.saveOcr(page, ocr('Water bill Pune'));
    await repo.clearIndex();
    expect(await repo.search('pune'), isEmpty);
    await repo.rebuildIndex();
    expect((await repo.search('pune')).length, 1);
    expect((await repo.search('Utility')).first.titleMatch, isTrue, reason: 'title search');
  });

  test('Devanagari text is searchable', () async {
    final doc = await repo.createDocument(title: 'Hindi');
    final page = await repo.addPage(doc.id, source('h.jpg').path);
    await repo.saveOcr(page, ocr('आधार पहचान पत्र नमूना'));
    expect((await repo.search('पहचान')).length, 1);
  });

  test('ACCEPTANCE 4: batch order is preserved and unfinished sessions are recovered', () async {
    final session = ScanSessionData(id: 'sess1', mode: 'scan', items: const [], updatedAt: DateTime.now());
    final items = <SessionItem>[];
    for (var i = 0; i < 3; i++) {
      final rel = 'sessions/sess1/p$i.jpg';
      repo.storage.file(rel)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(docPhoto(seed: i + 1));
      items.add(SessionItem(path: rel, rotation: i == 2 ? 90 : 0));
      await repo.saveSession(session.copyWith(items: [...items]));
    }
    // Simulate the app being killed and restarted.
    await adb.close();
    repo = await openRepo();
    final recovered = await repo.unfinishedSessions();
    expect(recovered.length, 1);
    expect(recovered.first.items.map((e) => e.path).toList(), ['sessions/sess1/p0.jpg', 'sessions/sess1/p1.jpg', 'sessions/sess1/p2.jpg']);
    expect(recovered.first.items[2].rotation, 90);

    final doc = await repo.createDocument(title: 'Batch');
    for (final it in recovered.first.items) {
      await repo.addPage(doc.id, repo.storage.abs(it.path), edit: PageEdit(rotation: it.rotation));
    }
    await repo.completeSession('sess1');
    expect(await repo.unfinishedSessions(), isEmpty);
    var pages = await repo.getPages(doc.id);
    expect(pages.map((p) => p.position).toList(), [0, 1, 2]);
    expect(pages[2].edit.rotation, 90);
    // Page originals were copied before the session folder was removed.
    expect(pages.every((p) => repo.storage.file(p.originalPath).existsSync()), isTrue);

    await repo.reorderPages(doc.id, [pages[2].id, pages[0].id, pages[1].id]);
    final reordered = await repo.getPages(doc.id);
    expect(reordered.map((p) => p.id).toList(), [pages[2].id, pages[0].id, pages[1].id]);

    await repo.deletePage(reordered[1]);
    pages = await repo.getPages(doc.id);
    expect(pages.length, 2);
    expect(pages.map((p) => p.position).toList(), [0, 1]);
    expect((await repo.getDocument(doc.id))!.pageCount, 2);
  });

  test('duplicate pages are flagged', () async {
    final doc = await repo.createDocument(title: 'Dup');
    final src = source('d.jpg');
    await repo.addPage(doc.id, src.path);
    final second = await repo.addPage(doc.id, src.path);
    expect(second.flags, contains(QualityFlag.duplicate));
    final dups = await repo.findDuplicatesByHash(second.hash!);
    expect(dups.map((d) => d.id), contains(doc.id));
  });

  test('duplicate page, copy keeps its own files', () async {
    final doc = await repo.createDocument(title: 'Copy');
    final p = await repo.addPage(doc.id, source('e.jpg').path);
    final copy = await repo.duplicatePage(p);
    expect(copy.originalPath, isNot(p.originalPath));
    await repo.deletePage(p);
    expect(repo.storage.file(copy.originalPath).existsSync(), isTrue);
  });

  test('duplicate document copies pages, OCR, tags and search text; size is reported', () async {
    final doc = await repo.createDocument(title: 'Lease');
    final page = await repo.addPage(doc.id, source('a.jpg').path);
    await repo.saveOcr(page, ocr('tenancy agreement'));
    await repo.setTags(doc.id, ['home']);
    final copy = await repo.duplicateDocument(doc.id);
    expect(copy.title, 'Lease (copy)');
    expect(copy.tags, ['home']);
    final pages = await repo.getPages(copy.id);
    expect(pages, hasLength(1));
    expect(pages.single.originalPath, isNot((await repo.getPages(doc.id)).single.originalPath));
    expect((await repo.search('tenancy')).map((h) => h.document.id).toSet(), {doc.id, copy.id});
    expect(await repo.documentSize(copy.id), greaterThan(1000));
    // Deleting the original leaves the copy intact.
    await repo.softDelete(doc.id);
    await repo.purge(doc.id);
    expect(File(AppStorage.instance.abs(pages.single.originalPath)).existsSync(), isTrue);
  });

  test('trash purge removes files; folders and tags', () async {
    final doc = await repo.createDocument(title: 'Trash me');
    await repo.addPage(doc.id, source('f.jpg').path);
    final folder = await repo.createFolder('Bills');
    await repo.moveToFolder(doc.id, folder.id);
    await repo.setTags(doc.id, ['tax', 'home']);
    expect((await repo.listDocuments(folderId: folder.id)).length, 1);
    expect((await repo.listDocuments(tag: 'tax')).length, 1);
    expect(await repo.allTags(), ['home', 'tax']);
    await repo.softDelete(doc.id);
    expect(await repo.listDocuments(), isEmpty);
    expect((await repo.listDocuments(deleted: true)).length, 1);
    await repo.emptyTrash();
    expect(Directory(repo.storage.abs(repo.storage.docDir(doc.id))).existsSync(), isFalse);
  });

  test('backup ZIP round trip restores pages and OCR', () async {
    final doc = await repo.createDocument(title: 'Passport copy');
    final page = await repo.addPage(doc.id, source('g.jpg').path);
    await repo.saveOcr(page, ocr('Republic of India passport'));
    await repo.setTags(doc.id, ['id']);
    final zip = await BackupService.exportDocuments(repo, [doc.id]);
    expect(File(zip).existsSync(), isTrue);
    final n = await BackupService.importArchive(repo, zip);
    expect(n, 1);
    final docs = await repo.listDocuments();
    expect(docs.length, 2);
    final restored = docs.firstWhere((d) => d.id != doc.id);
    expect(restored.title, 'Passport copy (restored)');
    expect(restored.tags, ['id']);
    final pages = await repo.getPages(restored.id);
    expect(pages.length, 1);
    expect(repo.storage.file(pages.first.originalPath).existsSync(), isTrue);
    expect((await repo.search('republic')).length, 2);
  });
}
