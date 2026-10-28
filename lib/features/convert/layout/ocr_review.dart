import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';

import '../model/doc_model.dart' show xmlEscape;

/// A word on a scanned page that needs a person's eye: read with low OCR
/// confidence (kept in the document, marked by a hidden bookmark
/// `_OCR_<id>` around its run, never highlighted unless asked), or left out
/// of the text because it belongs to a picture or looked like noise.
class OcrReviewItem {
  final int id; // bookmark number; 0 for words left out of the document
  final int page; // 1-based
  String text;
  final double? confidence;
  final String context; // the line it was read in
  final Rect box; // page points
  final bool omitted;
  OcrReviewItem({required this.id, required this.page, required this.text, this.confidence, this.context = '', required this.box, this.omitted = false});

  Map<String, Object?> toJson() => {
        'id': id,
        'page': page,
        'text': text,
        'confidence': confidence,
        'context': context,
        'box': [box.left, box.top, box.right, box.bottom].map((v) => double.parse(v.toStringAsFixed(1))).toList(),
        'omitted': omitted,
      };

  factory OcrReviewItem.fromJson(Map<String, Object?> j) {
    final b = (j['box'] as List).cast<num>();
    return OcrReviewItem(
      id: j['id'] as int,
      page: j['page'] as int,
      text: j['text'] as String,
      confidence: (j['confidence'] as num?)?.toDouble(),
      context: j['context'] as String? ?? '',
      box: Rect.fromLTRB(b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble()),
      omitted: j['omitted'] as bool? ?? false,
    );
  }

  /// Where the item is, for people: "page 1, top left".
  String where(Size page) {
    final c = box.center;
    final v = c.dy < page.height / 3 ? 'top' : (c.dy < page.height * 2 / 3 ? 'middle' : 'bottom');
    final h = c.dx < page.width / 3 ? 'left' : (c.dx < page.width * 2 / 3 ? 'centre' : 'right');
    return 'page $page, $v $h';
  }
}

/// The review file kept next to a converted document.
String reviewPathFor(String docxPath) => '$docxPath.review.json';

String encodeReview(List<OcrReviewItem> items, List<Size> pageSizes) => jsonEncode({
      'version': 1,
      'pages': [for (final s in pageSizes) [s.width, s.height]],
      'items': [for (final i in items) i.toJson()],
    });

(List<OcrReviewItem>, List<Size>) decodeReview(String json) {
  final j = jsonDecode(json) as Map<String, Object?>;
  return (
    [for (final i in (j['items'] as List)) OcrReviewItem.fromJson((i as Map).cast<String, Object?>())],
    [for (final s in (j['pages'] as List? ?? const [])) Size(((s as List)[0] as num).toDouble(), (s[1] as num).toDouble())],
  );
}

/// Writes corrected words into a DOCX made by writeLayoutDocx: the run
/// inside each `_OCR_<id>` bookmark gets the new text; nothing else in the
/// document changes, and no highlighting is added.
Uint8List applyOcrCorrections(Uint8List docx, Map<int, String> corrections) {
  final archive = ZipDecoder().decodeBytes(docx);
  final out = Archive();
  for (final f in archive.files) {
    if (f.name != 'word/document.xml') {
      out.addFile(ArchiveFile(f.name, f.size, f.content));
      continue;
    }
    var xml = utf8.decode(f.content as List<int>);
    for (final e in corrections.entries) {
      final re = RegExp('(<w:bookmarkStart w:id="\\d+" w:name="_OCR_${e.key}"/><w:r>(?:(?!</w:r>).)*?<w:t xml:space="preserve">)([^<]*)(</w:t>)');
      xml = xml.replaceFirstMapped(re, (m) => '${m[1]}${xmlEscape(e.value)}${m[3]}');
    }
    final bytes = utf8.encode(xml);
    out.addFile(ArchiveFile(f.name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(out)!);
}
