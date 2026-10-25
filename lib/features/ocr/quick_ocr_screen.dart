import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/import_service.dart';
import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import '../library/document_screen.dart';
import '../pdf/export_actions.dart';
import 'ocr_service.dart';
import 'text_analysis.dart';

/// One-tap "image to text": pick or capture an image and recognise it
/// without creating a document (optionally save it afterwards).
class QuickOcrScreen extends ConsumerStatefulWidget {
  const QuickOcrScreen({super.key});

  @override
  ConsumerState<QuickOcrScreen> createState() => _QuickOcrScreenState();
}

class _QuickOcrScreenState extends ConsumerState<QuickOcrScreen> {
  String? _path;
  OcrPageResult? _result;
  late String _script = ref.read(settingsProvider).ocrScript;

  Future<void> _pick({bool camera = false}) async {
    final p = camera ? await ImportService.captureWithSystemCamera() : (await ImportService.pickImages(multiple: false)).firstOrNull;
    if (p == null || !mounted) return;
    final r = await runBusy(context, 'Recognising text…', (ctl) async {
      final norm = await ImportService.normalize(p);
      // Normalise orientation so boxes match what is displayed.
      final out = ref.read(storageProvider).tempPath('quick_ocr.jpg');
      final (w, h) = await normalizeToJpeg(norm.path, out, maxPixels: 12000000);
      final res = await ocrService.recognizeFile(out, script: _script, imageWidth: w, imageHeight: h);
      return (out, res);
    });
    if (r == null || !mounted) return;
    setState(() {
      _path = r.$1;
      _result = r.$2;
    });
  }

  Future<void> _saveAsDocument() async {
    final path = _path;
    if (path == null) return;
    final repo = ref.read(repositoryProvider);
    final text = _result?.text ?? '';
    final names = TextAnalysis.suggestNames(text);
    final id = await runBusy(context, 'Saving…', (ctl) async {
      final doc = await repo.createDocument(title: Naming.unique(names.first, await repo.allTitles()), kind: DocKind.images, docType: TextAnalysis.classify(text));
      final page = await repo.addPage(doc.id, path, edit: const PageEdit(preset: FilterPreset.smartAuto), documentExpected: false);
      await ocrService.recognizePage(repo, page, _script);
      return doc.id;
    });
    if (id != null && mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DocumentScreen(docId: id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Extract text'),
        actions: [
          if (r != null) ...[
            IconButton(
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: r.text));
                showSnack(context, 'Copied');
              },
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: 'Share as TXT',
              onPressed: () => ExportActions.shareBytes(Uint8List.fromList(utf8.encode(r.text)), 'text.txt', mime: 'text/plain'),
              icon: const Icon(Icons.share_outlined),
            ),
          ],
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButton<String>(
          isExpanded: true,
          value: _script,
          items: [for (final s in OcrScript.all) DropdownMenuItem(value: s.id, child: Text(s.label))],
          onChanged: (v) => setState(() => _script = v ?? 'latin'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => _pick(camera: true), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Camera'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.tonalIcon(onPressed: () => _pick(), icon: const Icon(Icons.photo_library_outlined), label: const Text('Gallery'))),
        ]),
        const SizedBox(height: 12),
        if (_path != null) ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(_path!), height: 220, fit: BoxFit.contain)),
        if (r != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('${r.lines.length} lines · ${r.flaggedCount} to review', style: Theme.of(context).textTheme.bodySmall)),
            TextButton.icon(onPressed: _saveAsDocument, icon: const Icon(Icons.save_outlined), label: const Text('Save as document')),
          ]),
          if (r.lines.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No text found. Try better lighting or another language.'))),
          for (final l in r.lines)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: l.flagged ? Colors.amber.withValues(alpha: 0.22) : Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(l.text),
            ),
        ] else
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Text recognition runs on your device. Nothing is uploaded.', textAlign: TextAlign.center),
          ),
      ]),
    );
  }
}
