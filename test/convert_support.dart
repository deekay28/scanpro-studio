import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final r = Process.runSync('soffice', ['--headless', '-env:UserInstallation=file://${dir.path}/profile', '--convert-to', 'pdf', '--outdir', dir.path, f.path]);
  final out = File('${dir.path}/in.pdf');
  if (r.exitCode != 0 || !out.existsSync()) throw StateError('LibreOffice could not open the file: ${r.stdout}${r.stderr}');
  return out.readAsBytesSync();
}

bool get hasLibreOffice => Process.runSync('which', ['soffice']).exitCode == 0;
