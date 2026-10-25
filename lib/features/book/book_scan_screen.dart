import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/import_service.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import '../scanner/pro_camera_screen.dart';
import '../scanner/scan_flow.dart';
import 'book_review_screen.dart';

/// Book mode entry: capture or import two-page spreads, then split,
/// correct and order them in the review screen.
class BookScanScreen extends ConsumerWidget {
  const BookScanScreen({super.key});

  static Future<ScanSessionData> analyzeSpreads(DocumentRepository repo, ScanSessionData s, BusyController ctl) async {
    final items = <SessionItem>[];
    for (var i = 0; i < s.items.length; i++) {
      final it = s.items[i];
      if (it.spine != null) {
        items.add(it);
        continue;
      }
      ctl.update('Finding pages and spine ${i + 1} of ${s.items.length}…', (i + 1) / s.items.length);
      try {
        final a = await analyzeSpread(repo.storage.abs(it.path));
        items.add(it.copyWith(corners: a.spreadCorners, spine: a.spine));
      } catch (_) {
        items.add(it.copyWith(spine: 0.5));
      }
    }
    final out = s.copyWith(items: items);
    await repo.saveSession(out);
    return out;
  }

  Future<void> _camera(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repositoryProvider);
    final session = await ScanFlow.newSession(repo, 'book');
    if (!context.mounted) return;
    final r = await Navigator.of(context).push<ScanSessionData>(
      MaterialPageRoute(builder: (_) => ProCameraScreen(session: session, bookMode: true)),
    );
    await _continue(context, ref, r ?? session);
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repositoryProvider);
    final picked = await ImportService.pickImages();
    if (picked.isEmpty || !context.mounted) return;
    final s = await runBusy(context, 'Importing spreads…', (ctl) async {
      var session = await ScanFlow.newSession(repo, 'book');
      final items = <SessionItem>[];
      for (var i = 0; i < picked.length; i++) {
        ctl.update('Importing ${i + 1} of ${picked.length}…', (i + 1) / picked.length);
        final norm = await ImportService.normalize(picked[i]);
        items.add(await ScanFlow.makeItem(repo, session, norm.path, detectCorners: false, documentExpected: false, existing: items));
      }
      session = session.copyWith(items: items);
      await repo.saveSession(session);
      return session;
    });
    if (s != null && context.mounted) await _continue(context, ref, s);
  }

  Future<void> _continue(BuildContext context, WidgetRef ref, ScanSessionData s) async {
    final repo = ref.read(repositoryProvider);
    final fresh = (await repo.unfinishedSessions()).where((e) => e.id == s.id).firstOrNull;
    if (fresh == null || fresh.items.isEmpty) {
      await repo.discardSession(s.id);
      return;
    }
    if (!context.mounted) return;
    final analysed = await runBusy(context, 'Analysing spreads…', (ctl) => analyzeSpreads(repo, fresh, ctl));
    if (analysed == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BookReviewScreen(session: analysed)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Book scanner')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Icon(Icons.menu_book, size: 64, color: t.colorScheme.primary),
        const SizedBox(height: 12),
        Text('Scan two-page spreads', style: t.textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text(
          'Each photo of an open book is split at the spine into left and right pages, perspective-corrected, '
          'cleaned of shadows and put in reading order.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: () => _camera(context, ref), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Capture spreads')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _import(context, ref), icon: const Icon(Icons.photo_library_outlined), label: const Text('Import spread photos')),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
              Text('Tips for best results', style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Text('• Place the book on a dark, plain surface so page edges are visible.'),
              Text('• Hold the phone parallel to the pages; align the spine with the centre line.'),
              Text('• Press the book flat; keep fingers off the text.'),
              Text('• Use even light; avoid the phone\'s shadow.'),
              SizedBox(height: 8),
              Text(
                'Curved-page flattening is approximate: it straightens the top and bottom page edges. '
                'Text very deep in the gutter may stay slightly curved. Originals are always kept.',
                style: TextStyle(fontSize: 12),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
