import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../core/models.dart';
import '../../core/ocr_models.dart';
import '../../core/repository.dart';
import '../../core/storage.dart';
import 'text_analysis.dart';

/// OCR scripts bundled with the app. Each Google ML Kit script model also
/// recognises Latin characters, so "Devanagari" handles mixed Hindi-English.
class OcrScript {
  final String id;
  final String label;
  final String languages;
  const OcrScript(this.id, this.label, this.languages);

  static const latin = OcrScript('latin', 'English / Latin', 'English and other Latin-script languages');
  static const devanagari = OcrScript('devanagari', 'Hindi / Devanagari (+English)', 'Hindi, Marathi, Nepali, Sanskrit, and Latin text');
  static const all = [latin, devanagari];

  static OcrScript byId(String id) => all.firstWhere((s) => s.id == id, orElse: () => latin);
}

/// On-device OCR using Google ML Kit (no network access; models bundled).
class OcrService {
  final Map<String, TextRecognizer> _recognizers = {};

  TextRecognizer _recognizer(String script) {
    return _recognizers.putIfAbsent(script, () {
      final s = script == 'devanagari'
          // Look the enum up by name: the plugin's identifier spelling has varied.
          ? TextRecognitionScript.values.firstWhere((e) => e.name.toLowerCase().startsWith('devanag'),
              orElse: () => TextRecognitionScript.latin)
          : TextRecognitionScript.latin;
      return TextRecognizer(script: s);
    });
  }

  /// Recognises text in an image file. [imageWidth]/[imageHeight] are the
  /// pixel size of that file, stored so overlays can be scaled later.
  Future<OcrPageResult> recognizeFile(String absPath, {required String script, required int imageWidth, required int imageHeight}) async {
    if (!File(absPath).existsSync()) throw const FileSystemException('Page image is missing');
    final input = InputImage.fromFilePath(absPath);
    final r = await _recognizer(script).processImage(input);
    final lines = <OcrLine>[];
    var blockIndex = 0;
    for (final b in r.blocks) {
      for (final l in b.lines) {
        final conf = _confidenceOf(l);
        final box = l.boundingBox;
        lines.add(OcrLine(
          text: l.text,
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
          confidence: conf,
          flagged: TextAnalysis.needsReview(l.text, confidence: conf),
          block: blockIndex,
        ));
      }
      blockIndex++;
    }
    return OcrPageResult(
      script: script,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      lines: lines,
      createdAt: DateTime.now(),
    );
  }

  /// Words with their own boxes and confidences (ML Kit "elements"), for
  /// layout reconstruction. Falls back to splitting a line evenly when the
  /// engine returns no elements for it.
  Future<List<({String text, double left, double top, double right, double bottom, double? confidence, int line})>> recognizeWords(String absPath, {required String script}) async {
    final r = await _recognizer(script).processImage(InputImage.fromFilePath(absPath));
    final out = <({String text, double left, double top, double right, double bottom, double? confidence, int line})>[];
    var line = 0;
    for (final b in r.blocks) {
      for (final l in b.lines) {
        line++;
        if (l.elements.isNotEmpty) {
          for (final e in l.elements) {
            final box = e.boundingBox;
            out.add((text: e.text, left: box.left, top: box.top, right: box.right, bottom: box.bottom, confidence: e.confidence ?? _confidenceOf(l), line: line));
          }
          continue;
        }
        final parts = l.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (parts.isEmpty) continue;
        final box = l.boundingBox;
        final chars = parts.fold<int>(0, (n, w) => n + w.length) + parts.length - 1;
        final per = (box.right - box.left) / (chars == 0 ? 1 : chars);
        var x = box.left;
        for (final w in parts) {
          out.add((text: w, left: x, top: box.top, right: x + per * w.length, bottom: box.bottom, confidence: _confidenceOf(l), line: line));
          x += per * (w.length + 1);
        }
      }
    }
    return out;
  }

  /// Uses the engine confidence when the plugin version exposes it.
  double? _confidenceOf(TextLine line) {
    try {
      final dynamic d = line;
      final v = d.confidence;
      if (v is num) return v.toDouble();
    } catch (_) {}
    return null;
  }

  /// Runs OCR on one page and stores the result + search index.
  Future<OcrPageResult> recognizePage(DocumentRepository repo, DocPage page, String script) async {
    final path = AppStorage.instance.abs(page.displayPath);
    final result = await recognizeFile(path, script: script, imageWidth: page.width, imageHeight: page.height);
    await repo.saveOcr(page, result);
    return result;
  }

  /// Character count of text found; used to guess page orientation.
  Future<int> textAmount(String absPath, String script) async {
    final r = await _recognizer(script).processImage(InputImage.fromFilePath(absPath));
    return r.text.replaceAll(RegExp(r'\s'), '').length;
  }

  Future<void> dispose() async {
    for (final r in _recognizers.values) {
      await r.close();
    }
    _recognizers.clear();
  }
}

final ocrService = OcrService();
