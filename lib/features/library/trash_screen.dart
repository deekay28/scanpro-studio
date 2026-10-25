import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

/// Recently deleted documents with restore / permanent delete.
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final days = ref.watch(settingsProvider).trashRetentionDays;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently deleted'),
        actions: [
          TextButton(
            onPressed: () async {
              if (await confirm(context, 'Empty Recently deleted?', 'Documents will be permanently deleted from the app.', ok: 'Delete all', destructive: true)) {
                final n = await repo.emptyTrash();
                if (context.mounted) showSnack(context, '$n document(s) deleted');
              }
            },
            child: const Text('Empty'),
          ),
        ],
      ),
      body: FutureBuilder<List<ScanDocument>>(
        key: ValueKey(repo.revision),
        future: repo.listDocuments(deleted: true, sort: 'deleted'),
        builder: (ctx, snap) {
          final docs = snap.data;
          if (docs == null) return const Center(child: CircularProgressIndicator());
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Items are removed permanently after $days days (change in Settings). '
                'Deleting removes the files from app storage; phones cannot guarantee secure erasure of flash memory.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: docs.isEmpty
                  ? const EmptyState(icon: Icons.delete_outline, title: 'Nothing here')
                  : ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (ctx, i) {
                        final d = docs[i];
                        final left = days - DateTime.now().difference(d.deletedAt!).inDays;
                        return ListTile(
                          leading: SizedBox(width: 40, height: 52, child: StoredImage(d.coverThumb, cacheWidth: 100)),
                          title: Text(d.title),
                          subtitle: Text('Deleted ${relativeTime(d.deletedAt!)} · ${left < 0 ? 0 : left} days left'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(tooltip: 'Restore', icon: const Icon(Icons.restore), onPressed: () => repo.restore(d.id)),
                            IconButton(
                              tooltip: 'Delete permanently',
                              icon: const Icon(Icons.delete_forever_outlined),
                              onPressed: () async {
                                if (await confirm(ctx, 'Delete permanently?', '"${d.title}" cannot be recovered.', ok: 'Delete', destructive: true)) {
                                  await repo.purge(d.id);
                                }
                              },
                            ),
                          ]),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
