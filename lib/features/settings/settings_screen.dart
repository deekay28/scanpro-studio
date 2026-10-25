import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/units.dart';
import '../../shared/widgets.dart';
import '../backup/backup_screen.dart';
import '../ocr/ocr_service.dart';
import '../passport/calibration_screen.dart';
import '../passport/preset_editor_screen.dart';
import '../security/app_lock.dart';
import '../security/vault.dart';
import 'privacy_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final repo = ref.watch(repositoryProvider);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        const SectionHeader('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => s.setThemeMode(v.first),
          ),
        ),
        const SectionHeader('Scanning'),
        ListTile(
          title: const Text('Default filter'),
          subtitle: Text(s.defaultPreset.label),
          leading: const Icon(Icons.filter_vintage_outlined),
          onTap: () async {
            final v = await showDialog<FilterPreset>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('Default filter'),
                children: [
                  for (final p in FilterPreset.values)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, p),
                      child: ListTile(title: Text(p.label), subtitle: Text(p.description), selected: p == s.defaultPreset),
                    ),
                ],
              ),
            );
            if (v != null) await s.setDefaultPreset(v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('Processed page resolution'),
          subtitle: Text('${s.processingMaxDim} px longest side (originals are always kept in full resolution)'),
          onTap: () async {
            final v = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(title: const Text('Resolution'), children: [
                for (final (px, label) in [(2000, 'Standard (2000 px) – faster, smaller'), (2800, 'High (2800 px) – recommended'), (4000, 'Maximum (4000 px) – slow, large')])
                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, px), child: Text(label)),
              ]),
            );
            if (v != null) await s.setProcessingMaxDim(v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.crop_portrait),
          title: const Text('Default PDF page size'),
          subtitle: Text(PaperSizes.byId(s.defaultPageSize).toString()),
          onTap: () async {
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(title: const Text('Page size'), children: [
                for (final p in PaperSizes.documentSizes) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p.id), child: Text(p.toString())),
              ]),
            );
            if (v != null) await s.setDefaultPageSize(v);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.motion_photos_auto_outlined),
          title: const Text('Auto-capture in Pro camera'),
          subtitle: const Text('Take the photo when the page is detected and steady'),
          value: s.autoCapture,
          onChanged: s.setAutoCapture,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.warning_amber_outlined),
          title: const Text('Quality warnings'),
          subtitle: const Text('Flag blurry, dark, overexposed, cut-off or duplicate pages'),
          value: s.qualityWarnings,
          onChanged: s.setQualityWarnings,
        ),
        const SectionHeader('Text recognition & search'),
        ListTile(
          leading: const Icon(Icons.translate),
          title: const Text('OCR language'),
          subtitle: Text(OcrScript.byId(s.ocrScript).label),
          onTap: () async {
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(title: const Text('OCR language'), children: [
                for (final o in OcrScript.all)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, o.id),
                    child: ListTile(title: Text(o.label), subtitle: Text(o.languages)),
                  ),
              ]),
            );
            if (v != null) await s.setOcrScript(v);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.text_fields),
          title: const Text('Recognise text after scanning'),
          subtitle: const Text('Runs OCR automatically when saving scans'),
          value: s.autoOcr,
          onChanged: s.setAutoOcr,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.manage_search),
          title: const Text('Full-text search index'),
          subtitle: const Text('Index OCR and PDF text on this device for search'),
          value: s.searchIndexing,
          onChanged: (v) async {
            await s.setSearchIndexing(v);
            if (v) {
              if (context.mounted) await runBusy<void>(context, 'Building index…', (_) => repo.rebuildIndex());
            } else {
              await repo.clearIndex();
            }
          },
        ),
        FutureBuilder<int>(
          key: ValueKey(repo.revision),
          future: repo.indexedPageCount(),
          builder: (ctx, snap) => ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Search index'),
            subtitle: Text(repo.adb.ftsAvailable ? '${snap.data ?? 0} indexed page(s)' : 'Full-text engine unavailable; using basic search'),
            trailing: Wrap(children: [
              TextButton(onPressed: () => runBusy<void>(context, 'Rebuilding…', (_) => repo.rebuildIndex()), child: const Text('Rebuild')),
              TextButton(onPressed: repo.clearIndex, child: const Text('Clear')),
            ]),
          ),
        ),
        const SectionHeader('Passport & printing'),
        ListTile(leading: const Icon(Icons.portrait_outlined), title: const Text('Photo presets'), subtitle: const Text('View, edit and add ID photo sizes'), onTap: () => push(const PresetEditorScreen())),
        ListTile(leading: const Icon(Icons.straighten), title: const Text('Print calibration page'), onTap: () => push(const CalibrationScreen())),
        const SectionHeader('Privacy & security'),
        SwitchListTile(
          secondary: const Icon(Icons.lock_outline),
          title: const Text('App lock'),
          subtitle: const Text('Require fingerprint, face or screen lock to open the app'),
          value: s.appLock,
          onChanged: (v) async {
            if (v) {
              if (!await DeviceAuth.isAvailable()) {
                if (context.mounted) showSnack(context, 'Set up a screen lock on this device first.');
                return;
              }
              final ok = await DeviceAuth.authenticate('Confirm to enable app lock', onError: (m) {
                if (context.mounted) showSnack(context, m);
              });
              if (!ok) return;
            }
            await s.setAppLock(v);
          },
        ),
        ListTile(leading: const Icon(Icons.enhanced_encryption_outlined), title: const Text('Private vault'), onTap: () => push(const VaultScreen())),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('Recently deleted retention'),
          subtitle: Text('${s.trashRetentionDays} days'),
          onTap: () async {
            final v = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(title: const Text('Keep deleted documents for'), children: [
                for (final d in [7, 14, 30, 60, 90]) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text('$d days')),
              ]),
            );
            if (v != null) await s.setTrashRetentionDays(v);
          },
        ),
        ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: const Text('Privacy & permissions'), onTap: () => push(const PrivacyScreen())),
        const SectionHeader('Data'),
        ListTile(leading: const Icon(Icons.backup_outlined), title: const Text('Backup & restore'), onTap: () => push(const BackupScreen())),
        FutureBuilder<int>(
          key: ValueKey('usage${repo.revision}'),
          future: repo.storage.usageBytes(),
          builder: (ctx, snap) => ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Storage used'),
            subtitle: Text(snap.hasData ? formatBytes(snap.data!) : 'Calculating…'),
            trailing: TextButton(
              onPressed: () async {
                await repo.storage.clearCache();
                if (context.mounted) showSnack(context, 'Temporary files cleared');
              },
              child: const Text('Clear cache'),
            ),
          ),
        ),
        const SectionHeader('About'),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('ScanPro Studio 1.0.0'),
          subtitle: const Text('Offline document scanner, PDF toolkit, OCR and ID photo studio'),
          onTap: () => showLicensePage(context: context, applicationName: 'ScanPro Studio', applicationVersion: '1.0.0'),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}
