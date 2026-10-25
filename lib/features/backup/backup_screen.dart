import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import '../pdf/export_actions.dart';
import 'backup_service.dart';

/// Local backup and restore (ZIP). Nothing is uploaded anywhere: the user
/// decides where the archive goes (Files, SD card, Drive app, …).
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref, {required bool share}) async {
    final repo = ref.read(repositoryProvider);
    final path = await runBusy(context, 'Creating backup…', (_) => BackupService.exportAll(repo));
    if (path == null || !context.mounted) return;
    final size = await File(path).length();
    if (share) {
      await ExportActions.shareFiles([path]);
    } else {
      if (size > 400 * 1024 * 1024) {
        showSnack(context, 'Backup is ${formatBytes(size)}; use Share to send it to Files or Drive instead.');
        return;
      }
      final saved = await ExportActions.saveBytes(await File(path).readAsBytes(), p.basename(path));
      if (saved != null && context.mounted) showSnack(context, 'Backup saved (${formatBytes(size)})');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = r?.files.single.path;
    if (path == null || !context.mounted) return;
    final repo = ref.read(repositoryProvider);
    final n = await runBusy(context, 'Restoring…', (ctl) => BackupService.importArchive(repo, path, onStatus: (s) => ctl.update(s)));
    if (n != null && context.mounted) showSnack(context, '$n document(s) restored');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Back up all documents (originals, edits, OCR text, annotations, tags and folders) into one ZIP file. '
          'The archive is not encrypted — store it somewhere safe. Restoring adds documents; it never replaces existing ones.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: () => _export(context, ref, share: false), icon: const Icon(Icons.save_alt), label: const Text('Save backup to device')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _export(context, ref, share: true), icon: const Icon(Icons.share_outlined), label: const Text('Share backup (Files, Drive, …)')),
        const SizedBox(height: 24),
        FilledButton.tonalIcon(onPressed: () => _import(context, ref), icon: const Icon(Icons.unarchive_outlined), label: const Text('Restore from ZIP')),
        const SizedBox(height: 24),
        const Text('WebDAV / cloud sync is not built in. To keep an off-device copy, share the backup ZIP to a storage app you trust.',
            style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
