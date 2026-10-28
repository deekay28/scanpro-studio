import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:scanpro_studio/features/convert/model/page_content.dart';

/// Writes [bytes] to a temp file and opens it with python-docx / openpyxl /
/// python-pptx (independent readers). Returns their JSON summary.
Map<String, dynamic> officeSummary(Uint8List bytes, String ext) {
  final f = File('${Directory.systemTemp.createTempSync('office').path}/out.$ext')..writeAsBytesSync(bytes);
  final r = Process.runSync('python3', ['-I', 'test/tools/validate_office.py', f.path]);
  if (r.exitCode != 0) throw StateError('Office validation failed: ${r.stdout}${r.stderr}');
  return (jsonDecode(r.stdout as String) as Map<String, dynamic>)[f.path] as Map<String, dynamic>;
}

/// Converts with LibreOffice when it is installed (local runs); returns the
/// produced PDF or null when LibreOffice is not available.
Uint8List? libreOfficeToPdf(Uint8List bytes, String ext) {
  final which = Process.runSync('which', ['soffice']);
  if (which.exitCode != 0) return null;
  final dir = Directory.systemTemp.createTempSync('lo');
  final f = File('${dir.path}/in.$ext')..writeAsBytesSync(bytes);
  // `flutter test` sets FONTCONFIG_FILE to its test fonts; use the system's.
  final r = Process.runSync('soffice', ['--headless', '-env:UserInstallation=file://${dir.path}/profile', '--convert-to', 'pdf', '--outdir', dir.path, f.path],
      environment: {'FONTCONFIG_FILE': '/etc/fonts/fonts.conf'});
  final out = File('${dir.path}/in.pdf');
  if (r.exitCode != 0 || !out.existsSync()) throw StateError('LibreOffice could not open the file: ${r.stdout}${r.stderr}');
  return out.readAsBytesSync();
}

bool get hasLibreOffice => Process.runSync('which', ['soffice']).exitCode == 0;

/// Tesseract as a stand-in for ML Kit (which only runs on Android): words
/// with pixel boxes and confidences. Null when tesseract is not installed.
List<(String, double, double, double, double, double)>? tesseractWords(Uint8List png) {
  if (Process.runSync('which', ['tesseract']).exitCode != 0) return null;
  final dir = Directory.systemTemp.createTempSync('ocr');
  final f = File('${dir.path}/in.png')..writeAsBytesSync(png);
  final r = Process.runSync('tesseract', [f.path, 'stdout', '--psm', '3', 'tsv']);
  if (r.exitCode != 0) throw StateError('tesseract failed: ${r.stderr}');
  final out = <(String, double, double, double, double, double)>[];
  for (final line in (r.stdout as String).split('\n').skip(1)) {
    final c = line.split('\t');
    if (c.length < 12 || c[0] != '5' || c[11].trim().isEmpty) continue;
    final l = double.parse(c[6]), t = double.parse(c[7]), w = double.parse(c[8]), h = double.parse(c[9]);
    out.add((c[11].trim(), l, t, w, h, double.parse(c[10]) / 100));
  }
  dir.deleteSync(recursive: true);
  return out;
}

/// Tesseract words as an OCR engine reports them: text, box, confidence and
/// the engine's text line.
List<PdfWord>? tesseractPdfWords(Uint8List png, {String lang = 'eng'}) {
  if (!hasTesseract) return null;
  final dir = Directory.systemTemp.createTempSync('ocr');
  final f = File('${dir.path}/in.png')..writeAsBytesSync(png);
  final r = Process.runSync('tesseract', [f.path, 'stdout', '-l', lang, '--psm', '3', 'tsv']);
  dir.deleteSync(recursive: true);
  if (r.exitCode != 0) throw StateError('tesseract failed: ${r.stderr}');
  final ids = <String, int>{};
  return [
    for (final line in (r.stdout as String).split('\n').skip(1))
      if (line.split('\t') case final c when c.length >= 12 && c[0] == '5' && c[11].trim().isNotEmpty)
        PdfWord(c[11].trim(), Rect.fromLTWH(double.parse(c[6]), double.parse(c[7]), double.parse(c[8]), double.parse(c[9])),
            confidence: double.parse(c[10]) / 100, line: ids.putIfAbsent('${c[1]}-${c[2]}-${c[3]}-${c[4]}', () => ids.length)),
  ];
}

bool get hasTesseract => Process.runSync('which', ['tesseract']).exitCode == 0;

/// The pictures in a DOCX/XLSX/PPTX (path inside the package → bytes).
Map<String, Uint8List> officeMedia(String path) {
  final a = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  return {
    for (final f in a.files)
      if (f.isFile && f.name.contains('/media/')) f.name: Uint8List.fromList(f.content as List<int>),
  };
}

/// One XML part of an Office package as text.
String officeXml(String path, String part) {
  final a = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  return utf8.decode(a.files.firstWhere((f) => f.name == part).content as List<int>);
}
