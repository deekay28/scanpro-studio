import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../docsuite/suite.dart';
import '../../pdf/export_actions.dart';
import '../../pdf/pdf_viewer_screen.dart';
import '../../pdf_editor/engine/engine_worker.dart';
import '../model/doc_model.dart';
import '../ooxml/docx.dart';
import '../ooxml/pptx.dart';
import '../ooxml/xlsx.dart';

String mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
      '.pdf' => 'application/pdf',
      '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.tif' || '.tiff' => 'image/tiff',
      '.zip' => 'application/zip',
      '.html' => 'text/html',
      '.csv' => 'text/csv',
      _ => 'text/plain',
    };

/// Opens an output: PDFs in the app's viewer, everything else through
/// Android's share sheet ("Open with" another app).
Future<void> openOutput(BuildContext context, String path, String name) async {
  final bytes = await File(path).readAsBytes();
  if (!context.mounted) return;
  final ext = p.extension(name).toLowerCase();
  if (ext == '.pdf') {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(bytes: bytes, title: p.basenameWithoutExtension(name))));
  } else if (ext == '.jpg' || ext == '.jpeg' || ext == '.png') {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(appBar: AppBar(title: Text(name)), body: InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(bytes))))));
  } else {
    await ExportActions.shareBytes(bytes, name, mime: mimeFor(name));
  }
}

/// Shows what a converted file contains, read back with the app's own
/// parsers (proof that it opens), before the user shares or saves it.
class OutputPreview extends StatelessWidget {
  final String path;
  final String name;
  const OutputPreview({super.key, required this.path, required this.name});

  @override
  Widget build(BuildContext context) {
    final ext = p.extension(name).toLowerCase();
    return FutureBuilder<Widget>(
      future: _build(context, ext),
      builder: (ctx, snap) {
        if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('Preview not available: ${snap.error}'));
        return snap.data ?? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
      },
    );
  }

  Future<Widget> _build(BuildContext context, String ext) async {
    final bytes = await File(path).readAsBytes();
    switch (ext) {
      case '.jpg' || '.jpeg' || '.png':
        return Image.memory(bytes, fit: BoxFit.contain);
      case '.pdf':
        final suite = await DocSuite.get();
        final s = await suite.host.open(bytes);
        try {
          final images = <ui.Image>[];
          for (var i = 0; i < s.pageCount && i < 3; i++) {
            final r = await s.call<RenderedPage>('renderOriginal', [i, 0.6]);
            images.add(await _decode(r));
          }
          return Column(children: [
            Text('${s.pageCount} page(s)'),
            for (final im in images) Padding(padding: const EdgeInsets.all(6), child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.black26)), child: RawImage(image: im))),
          ]);
        } finally {
          s.close();
        }
      case '.docx':
        final m = await compute(readDocx, bytes);
        return _docPreview(m);
      case '.xlsx':
        final sheets = await compute(readXlsx, bytes);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final s in sheets.take(6)) ...[
            Padding(padding: const EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text('Sheet "${s.name}" · ${s.rows.length} rows', style: const TextStyle(fontWeight: FontWeight.w600))),
            _grid([for (final r in s.rows.take(30)) [for (final c in r) c.text]]),
          ]
        ]);
      case '.pptx':
        final deck = await compute(readPptx, bytes);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${deck.slides.length} slide(s), ${deck.width.round()}×${deck.height.round()} pt'),
          for (var i = 0; i < deck.slides.length && i < 20; i++)
            Card(
              child: ListTile(
                title: Text('Slide ${i + 1}${deck.slides[i].title.isEmpty ? '' : ': ${deck.slides[i].title}'}', maxLines: 2),
                subtitle: Text([
                  '${deck.slides[i].shapes.whereType<SlideText>().length} text box(es)',
                  '${deck.slides[i].shapes.whereType<SlidePicture>().length} picture(s)',
                  '${deck.slides[i].shapes.whereType<SlideTable>().length} table(s)',
                  '${deck.slides[i].shapes.whereType<SlideChart>().length} chart(s)',
                ].join(' · ')),
              ),
            ),
        ]);
      default:
        final text = utf8.decode(bytes.length > 60000 ? bytes.sublist(0, 60000) : bytes, allowMalformed: true);
        return SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12));
    }
  }

  static Future<ui.Image> _decode(RenderedPage r) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(r.rgba, r.width, r.height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  Widget _grid(List<List<String>> rows) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: Colors.black12),
          children: [
            for (final r in rows)
              TableRow(children: [
                for (var c = 0; c < rows.fold<int>(0, (m, x) => x.length > m ? x.length : m); c++)
                  Padding(padding: const EdgeInsets.all(4), child: Text(c < r.length ? r[c] : '', style: const TextStyle(fontSize: 12))),
              ]),
          ],
        ),
      );

  Widget _docPreview(DocModel m) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.header.isNotEmpty) Text('Header: ${m.header}', style: const TextStyle(color: Colors.grey)),
        for (final b in m.blocks.take(200))
          switch (b) {
            DocParagraph para => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${para.style == ParaStyle.bullet ? '• ' : ''}${para.text}',
                  style: TextStyle(
                    fontSize: switch (para.style) { ParaStyle.title => 22, ParaStyle.h1 => 19, ParaStyle.h2 => 17, ParaStyle.h3 => 15, _ => 13 },
                    fontWeight: para.style == ParaStyle.normal || para.style == ParaStyle.bullet || para.style == ParaStyle.numbered ? FontWeight.normal : FontWeight.bold,
                  ),
                ),
              ),
            DocTable t => _grid([for (final r in t.rows) [for (final c in r) c.text]]),
            DocImage i => Padding(padding: const EdgeInsets.all(4), child: Image.memory(i.bytes, height: 80)),
            DocPageBreak _ => const Divider(),
          },
      ]);
}
