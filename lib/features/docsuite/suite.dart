import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../core/storage.dart';
import '../convert/conversion_jobs.dart';
import '../convert/conversion_service.dart';
import '../convert/model/page_content.dart';
import '../ocr/ocr_service.dart';
import '../pdf_editor/engine/engine_worker.dart';

/// App-wide document services: the shared PDFium host, the conversion
/// service (with on-device ML Kit OCR) and the conversion job queue.
class DocSuite {
  final Uint8List unicodeFont;
  final PdfiumHost host;
  final ConversionService conversions;
  final ConversionJobManager jobs;

  DocSuite._(this.unicodeFont, this.host, this.conversions, this.jobs);

  static Future<DocSuite>? _instance;
  static DocSuite? _ready;

  /// The suite if it has already been started (does not start it).
  static DocSuite? get started => _ready;
  static Future<DocSuite> get() => _instance ??= _create();

  /// Widget tests create the suite inside a fake-async zone where it can
  /// never complete; tests that need real document work reset it first.
  static void resetForTest() {
    _instance = null;
    _ready = null;
  }

  static Future<DocSuite> _create() async {
    final d = await rootBundle.load('assets/fonts/FreeSans.ttf');
    final font = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    final host = await PdfiumHost.start(font);
    final service = ConversionService(unicodeFont: font, ocr: mlKitOcr);
    final jobs = ConversionJobManager(
      root: AppStorage.instance.abs('conversions'),
      runner: (job, outDir, onProgress, cancel) => service.run(
        job.type,
        [for (final i in job.inputs) (i.path, i.name, job.passwords[i.name])],
        job.options,
        outDir,
        job.outputName,
        onProgress: onProgress,
        cancel: cancel,
      ),
    );
    await jobs.load();
    return _ready = DocSuite._(font, host, service, jobs);
  }
}

/// ML Kit OCR on a rendered page. Lines are split into words whose boxes
/// are spread over the line by character count.
Future<List<PdfWord>> mlKitOcr(Uint8List png, int width, int height, String script) async {
  final path = AppStorage.instance.tempPath('convert_ocr.png');
  await File(path).writeAsBytes(png);
  final ocr = OcrService();
  try {
    final r = await ocr.recognizeFile(path, script: script, imageWidth: width, imageHeight: height);
    final words = <PdfWord>[];
    for (final l in r.lines) {
      final parts = l.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      final chars = parts.fold<int>(0, (n, w) => n + w.length) + parts.length - 1;
      var x = l.left;
      final per = (l.right - l.left) / (chars == 0 ? 1 : chars);
      for (final w in parts) {
        final wWidth = per * w.length;
        words.add(PdfWord(w, Rect.fromLTWH(x, l.top, wWidth, l.bottom - l.top), confidence: l.confidence ?? (l.flagged ? 0.5 : 0.9)));
        x += wWidth + per;
      }
    }
    return words;
  } finally {
    await ocr.dispose();
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

/// Writes bytes to a temp file named [name] (for passing in-memory PDFs to
/// the job queue, which copies its inputs).
Future<String> tempFileFor(Uint8List bytes, String name) async {
  final dir = Directory(AppStorage.instance.tempPath('in'));
  await dir.create(recursive: true);
  final f = File(p.join(dir.path, name));
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
