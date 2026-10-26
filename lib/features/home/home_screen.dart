import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import '../book/book_scan_screen.dart';
import '../convert/ui/conversion_centre_screen.dart';
import '../docsuite/ui/pdf_suite_menu.dart';
import '../library/library_screen.dart';
import '../ocr/quick_ocr_screen.dart';
import '../passport/passport_studio_screen.dart';
import '../pdf/pdf_tools_screen.dart';
import '../scanner/scan_flow.dart';
import '../shell/main_shell.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final t = Theme.of(context);
    final actions = <(IconData, String, String, VoidCallback)>[
      (Icons.document_scanner, 'Scan document', 'Auto edges & capture', () => ScanFlow.smartScan(context, ref)),
      (Icons.photo_library, 'Import images', 'From gallery', () => ScanFlow.importImages(context, ref)),
      (Icons.picture_as_pdf, 'Multi-page PDF', 'Images → PDF', () => ScanFlow.showAddSheet(context, ref)),
      (Icons.menu_book, 'Scan a book', 'Split spreads', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BookScanScreen()))),
      (Icons.portrait, 'Passport photos', 'Print-ready sheet', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PassportStudioScreen()))),
      (Icons.text_fields, 'Extract text', 'On-device OCR', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickOcrScreen()))),
      (Icons.merge_type, 'Merge PDFs', 'Combine files', () => PdfTools.merge(context, ref)),
      (Icons.compress, 'Compress PDF', 'Email / print', () => PdfTools.pickAndCompress(context, ref)),
      (Icons.swap_horiz, 'Convert', 'PDF ⇄ Office, images', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConversionCentreScreen()))),
      (Icons.chrome_reader_mode_outlined, 'Read PDF', 'Night & book modes', () => PdfSuiteMenu.pickThen(context, 'read')),
      (Icons.edit_note, 'Fill & sign', 'PDF forms', () => PdfSuiteMenu.pickThen(context, 'fill')),
      (Icons.compare, 'Compare PDFs', 'Find changes', () => PdfSuiteMenu.pickThen(context, 'compare')),
    ];
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('ScanPro Studio', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('Private, offline scanning & printing', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                Tooltip(
                  message: 'Works offline. Documents never leave your device unless you share them.',
                  child: Chip(avatar: const Icon(Icons.shield_outlined, size: 18), label: const Text('Offline')),
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(child: _ResumeBanner()),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: _HeroScanCard(
                onScan: () => ScanFlow.smartScan(context, ref),
                onCamera: () => ScanFlow.proCamera(context, ref),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 104, mainAxisSpacing: 10, crossAxisSpacing: 10),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final a = actions[i];
                  return Card(
                    child: InkWell(
                      onTap: a.$4,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(a.$1, color: t.colorScheme.primary),
                          const Spacer(),
                          Text(a.$2, style: t.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(a.$3, style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ),
                  );
                },
                childCount: actions.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SectionHeader('Recent', trailing: TextButton(onPressed: () => shellTab.value = 1, child: const Text('See all'))),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<List<ScanDocument>>(
              key: ValueKey('recent${repo.revision}'),
              future: repo.listDocuments(limit: 12),
              builder: (ctx, snap) => _DocStrip(snap.data, empty: 'Your scans will appear here'),
            ),
          ),
          SliverToBoxAdapter(child: const SectionHeader('Favourites')),
          SliverToBoxAdapter(
            child: FutureBuilder<List<ScanDocument>>(
              key: ValueKey('fav${repo.revision}'),
              future: repo.listDocuments(favouritesOnly: true, limit: 12),
              builder: (ctx, snap) => _DocStrip(snap.data, empty: 'Tap ☆ on a document to pin it here'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]),
      ),
    );
  }
}

class _HeroScanCard extends StatelessWidget {
  final VoidCallback onScan;
  final VoidCallback onCamera;
  const _HeroScanCard({required this.onScan, required this.onCamera});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(colors: [s.primary, s.tertiary], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      padding: const EdgeInsets.all(20),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Scan to PDF', style: TextStyle(color: s.onPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Edge detection, perspective correction and filters — all on your device.', style: TextStyle(color: s.onPrimary.withValues(alpha: 0.9))),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: s.onPrimary, foregroundColor: s.primary),
                onPressed: onScan,
                icon: const Icon(Icons.document_scanner),
                label: const Text('Scan'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: s.onPrimary, side: BorderSide(color: s.onPrimary)),
                onPressed: onCamera,
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Pro camera'),
              ),
            ]),
          ]),
        ),
        Icon(Icons.description, size: 72, color: s.onPrimary.withValues(alpha: 0.25)),
      ]),
    );
  }
}

class _ResumeBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    return FutureBuilder<List<ScanSessionData>>(
      key: ValueKey('sessions${repo.revision}'),
      future: repo.unfinishedSessions(),
      builder: (ctx, snap) {
        final sessions = snap.data ?? const [];
        if (sessions.isEmpty) return const SizedBox.shrink();
        final s = sessions.first;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.restore_page_outlined),
              title: const Text('Unfinished scan recovered'),
              subtitle: Text('${s.items.length} page(s) captured — continue where you left off'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Discard',
                  onPressed: () async {
                    if (await confirm(context, 'Discard unfinished scan?', 'The captured pages will be deleted.', ok: 'Discard', destructive: true)) {
                      await repo.discardSession(s.id);
                    }
                  },
                  icon: const Icon(Icons.close),
                ),
                FilledButton(onPressed: () => ScanFlow.resume(context, ref, s), child: const Text('Resume')),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _DocStrip extends StatelessWidget {
  final List<ScanDocument>? docs;
  final String empty;
  const _DocStrip(this.docs, {required this.empty});

  @override
  Widget build(BuildContext context) {
    final d = docs;
    if (d == null) return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()));
    if (d.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text(empty, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: d.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (ctx, i) => SizedBox(width: 130, child: DocumentCard(doc: d[i])),
      ),
    );
  }
}
