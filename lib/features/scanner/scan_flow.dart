import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/import_service.dart';
import '../../core/models.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../imaging/processor.dart';
import '../../imaging/quality.dart';
import '../../shared/widgets.dart';
import '../book/book_review_screen.dart';
import 'pro_camera_screen.dart';
import 'review_screen.dart';

/// Entry points for every capture/import workflow. All captured images go
/// into a persistent session first, so an app crash or kill never loses
/// pages; the session is converted into a document on "Save".
class ScanFlow {
  static Future<ScanSessionData> newSession(DocumentRepository repo, String mode, {String? targetDocId}) async {
    final s = ScanSessionData(id: newId(), mode: mode, targetDocId: targetDocId, items: const [], updatedAt: DateTime.now());
    await repo.storage.ensureDir(repo.storage.sessionDir(s.id));
    await repo.saveSession(s);
    return s;
  }

  /// Copies [srcPath] into the session folder and analyses it (quality
  /// flags, duplicate hash, document corners).
  static Future<SessionItem> makeItem(
    DocumentRepository repo,
    ScanSessionData session,
    String srcPath, {
    bool detectCorners = true,
    bool documentExpected = true,
    List<SessionItem> existing = const [],
    bool downscaled = false,
  }) async {
    final ext = p.extension(srcPath).isEmpty ? '.jpg' : p.extension(srcPath).toLowerCase();
    final rel = p.join(repo.storage.sessionDir(session.id), '${newId()}$ext');
    await repo.storage.ensureDir(p.dirname(rel));
    await repo.storage.file(srcPath).copy(repo.storage.abs(rel));
    final a = await analyzeImage(repo.storage.abs(rel), documentExpected: documentExpected);
    final flags = [...a.flags];
    if (downscaled) flags.add(QualityFlag.downscaled);
    if (existing.any((e) => e.hash != null && isDuplicateHash(e.hash!, a.hash))) flags.add(QualityFlag.duplicate);
    return SessionItem(
      path: rel,
      corners: detectCorners && a.detectionScore >= 0.5 ? a.corners : null,
      flags: flags,
      hash: a.hash,
    );
  }

  /// Google ML Kit document scanner: live edge detection, auto-capture,
  /// perspective correction and cleanup handled on-device by Google Play
  /// services. Falls back to the built-in camera if unavailable.
  static Future<void> smartScan(BuildContext context, WidgetRef ref, {String? targetDocId}) async {
    final repo = ref.read(repositoryProvider);
    List<String> paths = const [];
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(mode: ScannerMode.full, pageLimit: 100, isGalleryImport: true),
    );
    try {
      final dynamic result = await scanner.scanDocument();
      final dynamic images = result?.images;
      if (images is List) paths = images.map((e) => e.toString()).toList();
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('cancel')) return;
      if (!context.mounted) return;
      final useBuiltIn = await confirm(
        context,
        'Smart scanner unavailable',
        'The Google document scanner could not start on this device (it needs Google Play services).\n\nUse the built-in camera scanner instead?',
        ok: 'Use built-in camera',
      );
      if (useBuiltIn && context.mounted) await proCamera(context, ref, targetDocId: targetDocId);
      return;
    } finally {
      await scanner.close();
    }
    if (paths.isEmpty || !context.mounted) return;
    final session = await runBusy<ScanSessionData>(context, 'Preparing pages…', (ctl) async {
      var s = await newSession(repo, 'scan', targetDocId: targetDocId);
      final items = <SessionItem>[];
      for (var i = 0; i < paths.length; i++) {
        ctl.update('Preparing page ${i + 1} of ${paths.length}…', (i + 1) / paths.length);
        // Already cropped by the scanner: keep corners null.
        items.add(await makeItem(repo, s, paths[i], detectCorners: false, existing: items));
        s = s.copyWith(items: [...items]);
        await repo.saveSession(s);
      }
      return s;
    });
    if (session != null && context.mounted) await openReview(context, session);
  }

  /// Built-in camera with live edge overlay, auto-capture, torch, focus and
  /// exposure controls.
  static Future<void> proCamera(BuildContext context, WidgetRef ref, {String? targetDocId, ScanSessionData? resume}) async {
    final repo = ref.read(repositoryProvider);
    final session = resume ?? await newSession(repo, 'scan', targetDocId: targetDocId);
    if (!context.mounted) return;
    final result = await Navigator.of(context).push<ScanSessionData>(
      MaterialPageRoute(builder: (_) => ProCameraScreen(session: session)),
    );
    final s = result ?? session;
    final fresh = (await repo.unfinishedSessions()).where((e) => e.id == s.id).firstOrNull;
    if (fresh == null || fresh.items.isEmpty) {
      await repo.discardSession(s.id);
      return;
    }
    if (context.mounted) await openReview(context, fresh);
  }

  /// Gallery import via the Android Photo Picker.
  static Future<void> importImages(BuildContext context, WidgetRef ref, {String? targetDocId, bool files = false}) async {
    final repo = ref.read(repositoryProvider);
    List<String> picked;
    try {
      picked = files ? await ImportService.pickImageFiles() : await ImportService.pickImages();
    } catch (e) {
      if (context.mounted) showSnack(context, 'Could not open the picker: $e');
      return;
    }
    if (picked.isEmpty || !context.mounted) return;
    final errors = <String>[];
    final session = await runBusy<ScanSessionData>(context, 'Importing images…', (ctl) async {
      var s = await newSession(repo, 'import', targetDocId: targetDocId);
      final items = <SessionItem>[];
      for (var i = 0; i < picked.length; i++) {
        if (ctl.cancelled) break;
        ctl.update('Importing ${i + 1} of ${picked.length}…', (i + 1) / picked.length);
        try {
          final norm = await ImportService.normalize(picked[i]);
          items.add(await makeItem(repo, s, norm.path, existing: items, downscaled: norm.downscaled));
          s = s.copyWith(items: [...items]);
          await repo.saveSession(s);
        } catch (e) {
          errors.add('${p.basename(picked[i])}: $e');
        }
      }
      return s;
    }, cancellable: true);
    if (!context.mounted) return;
    if (errors.isNotEmpty) {
      showSnack(context, '${errors.length} file(s) skipped (unsupported or damaged).');
    }
    if (session == null) return;
    if (session.items.isEmpty) {
      await repo.discardSession(session.id);
      return;
    }
    await openReview(context, session);
  }

  static Future<void> openReview(BuildContext context, ScanSessionData session) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => session.mode == 'book' ? BookReviewScreen(session: session) : ReviewScreen(session: session),
    ));
  }

  static Future<void> resume(BuildContext context, WidgetRef ref, ScanSessionData s) => openReview(context, s);

  /// Bottom sheet with every way of adding pages.
  static Future<void> showAddSheet(BuildContext context, WidgetRef ref, {String? targetDocId}) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Smart scan'),
            subtitle: const Text('Auto edge detection & capture (Google on-device scanner)'),
            onTap: () {
              Navigator.pop(ctx);
              smartScan(context, ref, targetDocId: targetDocId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Pro camera'),
            subtitle: const Text('Live edge overlay, auto-capture, torch, focus & exposure'),
            onTap: () {
              Navigator.pop(ctx);
              proCamera(context, ref, targetDocId: targetDocId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Import from gallery'),
            subtitle: const Text('Select one or many photos'),
            onTap: () {
              Navigator.pop(ctx);
              importImages(context, ref, targetDocId: targetDocId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Import image files'),
            subtitle: const Text('From Files, Drive or other providers'),
            onTap: () {
              Navigator.pop(ctx);
              importImages(context, ref, targetDocId: targetDocId, files: true);
            },
          ),
        ]),
      ),
    );
  }
}
