import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/import_service.dart';
import '../../shared/widgets.dart';
import '../pdf/export_actions.dart';

/// Reads QR codes and barcodes from a photo, on-device (ML Kit).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  String? _path;
  List<Barcode>? _codes;

  Future<void> _pick({bool camera = false}) async {
    final p = camera ? await ImportService.captureWithSystemCamera() : (await ImportService.pickImages(multiple: false)).firstOrNull;
    if (p == null || !mounted) return;
    final codes = await runBusy(context, 'Reading codes…', (_) async {
      final scanner = BarcodeScanner(formats: [BarcodeFormat.all]);
      try {
        return await scanner.processImage(InputImage.fromFilePath(p));
      } finally {
        await scanner.close();
      }
    });
    if (!mounted) return;
    setState(() {
      _path = p;
      _codes = codes ?? const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final codes = _codes;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR / barcode')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => _pick(camera: true), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Camera'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.tonalIcon(onPressed: () => _pick(), icon: const Icon(Icons.photo_library_outlined), label: const Text('From image'))),
        ]),
        const SizedBox(height: 12),
        if (_path != null) ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(_path!), height: 220, fit: BoxFit.contain)),
        if (codes != null && codes.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No QR code or barcode found.'))),
        for (final c in codes ?? const <Barcode>[])
          Card(
            margin: const EdgeInsets.only(top: 10),
            child: ListTile(
              leading: Icon(c.format == BarcodeFormat.qrCode ? Icons.qr_code_2 : Icons.view_week_outlined),
              title: SelectableText(c.displayValue ?? c.rawValue ?? ''),
              subtitle: Text('${c.format.name} · ${c.type.name}'),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: c.rawValue ?? ''));
                  showSnack(context, 'Copied');
                },
              ),
            ),
          ),
        const SizedBox(height: 16),
        const Text('Links are shown, not opened automatically. Check a link before visiting it.', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}

/// Generates a QR code and shares it as a PNG.
class QrGenerateScreen extends StatefulWidget {
  final String initialText;
  final String title;
  const QrGenerateScreen({super.key, this.initialText = '', this.title = 'Create QR code'});

  @override
  State<QrGenerateScreen> createState() => _QrGenerateScreenState();
}

class _QrGenerateScreenState extends State<QrGenerateScreen> {
  late final _text = TextEditingController(text: widget.initialText);
  final _key = GlobalKey();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    try {
      final boundary = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      await ExportActions.shareBytes(data.buffer.asUint8List(), 'qr_code.png', mime: 'image/png');
    } catch (e) {
      if (mounted) showSnack(context, 'Could not export: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _text.text.trim();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(onPressed: value.isEmpty ? null : _share, icon: const Icon(Icons.share_outlined), tooltip: 'Share PNG'),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _text,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Text or link'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        if (value.isNotEmpty)
          Center(
            child: RepaintBoundary(
              key: _key,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: QrImageView(data: value, size: 240, backgroundColor: Colors.white),
              ),
            ),
          ),
        if (widget.initialText.startsWith('scanpro://'))
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'This QR code is a local reference to the document inside ScanPro Studio on this device. '
              'It contains the document ID and title only — never the document content.',
              style: TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
      ]),
    );
  }
}
