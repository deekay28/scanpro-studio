import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/naming.dart';
import '../../core/storage.dart';

/// Save / share / print helpers. Saving uses the Storage Access Framework
/// (the user picks the destination); the app needs no storage permission.
class ExportActions {
  /// Returns the saved location, or null if the user cancelled.
  static Future<String?> saveBytes(Uint8List bytes, String fileName) async {
    final name = Naming.sanitize(fileName, maxLength: 120);
    return FilePicker.platform.saveFile(dialogTitle: 'Save as', fileName: name, bytes: bytes);
  }

  static Future<String> writeTemp(Uint8List bytes, String fileName) async {
    final dir = Directory(p.join(AppStorage.instance.cache.path, 'share_${DateTime.now().microsecondsSinceEpoch}'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, Naming.sanitize(fileName, maxLength: 120)));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  static Future<void> shareBytes(Uint8List bytes, String fileName, {String? mime, String? text}) async {
    final path = await writeTemp(bytes, fileName);
    await Share.shareXFiles([XFile(path, mimeType: mime)], text: text);
  }

  static Future<void> shareFiles(List<String> paths, {String? text}) async {
    await Share.shareXFiles(paths.map((e) => XFile(e)).toList(), text: text);
  }

  static Future<void> shareText(String text, {String? subject}) => Share.share(text, subject: subject);

  /// Sends the PDF to Android's print framework.
  static Future<bool> printPdf(Uint8List bytes, String name) =>
      Printing.layoutPdf(onLayout: (_) async => bytes, name: Naming.sanitize(name));
}
