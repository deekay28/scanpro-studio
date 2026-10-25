import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/repository.dart';
import '../../shared/widgets.dart';
import 'pdf_service.dart';

/// A PDF loaded into memory together with the password used to open it.
class LoadedPdf {
  final Uint8List bytes;
  final String name;
  final String? password;
  final PdfInfo info;
  const LoadedPdf(this.bytes, this.name, this.password, this.info);
  PdfSource get source => PdfSource(bytes, password: password);
}

class PdfLibrary {
  /// Picks one or more PDFs via the system picker (no storage permission).
  static Future<List<(Uint8List, String)>> pickPdfs({bool multiple = false}) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], allowMultiple: multiple, withData: false);
    if (r == null) return const [];
    final out = <(Uint8List, String)>[];
    for (final f in r.files) {
      final path = f.path;
      if (path == null) continue;
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) throw FormatException('${f.name} is empty.');
      if (bytes.length < 5 || String.fromCharCodes(bytes.sublist(0, 5)) != '%PDF-') {
        throw FormatException('${f.name} is not a valid PDF file.');
      }
      out.add((bytes, p.basenameWithoutExtension(f.name)));
    }
    return out;
  }

  /// Opens a PDF, asking for the password when needed. Returns null if the
  /// user cancels.
  static Future<LoadedPdf?> open(BuildContext context, Uint8List bytes, String name) async {
    String? password;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final info = PdfService.inspect(PdfSource(bytes, password: password));
        return LoadedPdf(bytes, name, password, info);
      } on PdfPasswordRequired {
        if (!context.mounted) return null;
        password = await promptText(
          context,
          attempt == 0 ? '"$name" is password protected' : 'Incorrect password, try again',
          hint: 'PDF password',
          obscure: true,
          ok: 'Open',
        );
        if (password == null) return null;
      }
    }
    return null;
  }

  static Future<List<LoadedPdf>> pickAndOpen(BuildContext context, {bool multiple = false}) async {
    final picked = await pickPdfs(multiple: multiple);
    final out = <LoadedPdf>[];
    for (final (bytes, name) in picked) {
      if (!context.mounted) break;
      final l = await open(context, bytes, name);
      if (l != null) out.add(l);
    }
    return out;
  }

  /// Saves PDF bytes as a library document (kind = pdf). The file is stored
  /// unchanged; its text layer (if any) is extracted and indexed for search.
  static Future<ScanDocument> saveToLibrary(DocumentRepository repo, Uint8List bytes, String title,
      {String? parentId, String? password, DocKind kind = DocKind.pdf}) async {
    final info = PdfService.inspect(PdfSource(bytes, password: password));
    final doc = await repo.createDocument(
      title: Naming.unique(Naming.sanitize(title, maxLength: 120), await repo.allTitles()),
      kind: kind,
      parentId: parentId,
      pageCount: info.pageCount,
    );
    final rel = p.join(repo.storage.docDir(doc.id), 'document.pdf');
    await repo.storage.ensureDir(p.dirname(rel));
    await repo.storage.file(rel).writeAsBytes(bytes, flush: true);
    await repo.db.update('documents', {'pdf_path': rel, 'page_count': info.pageCount}, where: 'id = ?', whereArgs: [doc.id]);
    try {
      final texts = PdfService.extractText(PdfSource(bytes, password: password));
      await repo.indexPdfText(doc.id, texts);
    } catch (_) {}
    repo.changed();
    return (await repo.getDocument(doc.id))!;
  }

  static Future<Uint8List> readDocPdf(DocumentRepository repo, ScanDocument doc) async {
    final rel = doc.pdfPath;
    if (rel == null) throw const FileSystemException('PDF file missing');
    return repo.storage.file(rel).readAsBytes();
  }
}
