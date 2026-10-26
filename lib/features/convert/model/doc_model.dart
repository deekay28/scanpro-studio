import 'dart:typed_data';

/// A format-neutral rich document used between converters:
/// PDF/HTML/TXT/DOCX → DocModel → DOCX/PDF/HTML.
class DocRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final double? size; // points; null = paragraph default
  final int? color; // ARGB
  final String? font; // family name
  final String? link; // hyperlink target
  const DocRun(this.text, {this.bold = false, this.italic = false, this.underline = false, this.size, this.color, this.font, this.link});
}

enum ParaStyle { normal, title, h1, h2, h3, bullet, numbered }

enum ParaAlign { left, center, right, justify }

sealed class DocBlock {
  const DocBlock();
}

class DocParagraph extends DocBlock {
  final List<DocRun> runs;
  final ParaStyle style;
  final ParaAlign align;
  final double indentLeft; // points
  final double spaceBefore; // points
  final int listLevel;
  const DocParagraph(this.runs, {this.style = ParaStyle.normal, this.align = ParaAlign.left, this.indentLeft = 0, this.spaceBefore = 0, this.listLevel = 0});

  String get text => runs.map((r) => r.text).join();
  bool get isEmpty => text.trim().isEmpty;
}

class DocTableCell {
  final String text;
  final bool bold;
  final double? number; // parsed numeric value (for spreadsheets)
  final bool uncertain; // low-confidence OCR or ambiguous parse
  const DocTableCell(this.text, {this.bold = false, this.number, this.uncertain = false});
}

class DocTable extends DocBlock {
  final List<List<DocTableCell>> rows;
  final bool headerRow;
  final List<double>? columnWidths; // points
  const DocTable(this.rows, {this.headerRow = false, this.columnWidths});
  int get columnCount => rows.fold(0, (m, r) => r.length > m ? r.length : m);
}

class DocImage extends DocBlock {
  final Uint8List bytes; // PNG or JPEG
  final double width; // points
  final double height; // points
  final double? x; // anchored position from the page's top-left (layout mode)
  final double? y;
  const DocImage(this.bytes, this.width, this.height, {this.x, this.y});
  bool get isJpeg => bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
}

class DocPageBreak extends DocBlock {
  /// Size and margins of the page that just ended (for per-page sections).
  final double? pageWidth;
  final double? pageHeight;
  const DocPageBreak({this.pageWidth, this.pageHeight});
}

class DocModel {
  final List<DocBlock> blocks;
  final String header;
  final String footer;
  final double pageWidth; // points (of the last section)
  final double pageHeight;
  final double margin; // points
  final String title;
  const DocModel(this.blocks, {this.header = '', this.footer = '', this.pageWidth = 595.28, this.pageHeight = 841.89, this.margin = 54, this.title = ''});

  String get plainText {
    final sb = StringBuffer();
    for (final b in blocks) {
      switch (b) {
        case DocParagraph p:
          sb.writeln(p.text);
        case DocTable t:
          for (final r in t.rows) {
            sb.writeln(r.map((c) => c.text).join('\t'));
          }
        case DocPageBreak _:
          sb.writeln();
        case DocImage _:
          break;
      }
    }
    return sb.toString();
  }
}

String xmlEscape(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x26:
        sb.write('&amp;');
      case 0x3C:
        sb.write('&lt;');
      case 0x3E:
        sb.write('&gt;');
      case 0x22:
        sb.write('&quot;');
      case 0x27:
        sb.write('&apos;');
      default:
        // XML 1.0 forbids most control characters.
        if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) continue;
        if (r == 0xFFFE || r == 0xFFFF) continue;
        sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

/// Maps a PDF font name to a family that office apps have.
String officeFontFor(String pdfFont) {
  var f = pdfFont.replaceFirst(RegExp(r'^[A-Z]{6}\+'), '');
  f = f.replaceAll(RegExp(r'[-,](Bold|Italic|Oblique|BoldItalic|BoldOblique|Regular|Roman|Medium|Light|Semibold|SemiBold|Black)+$', caseSensitive: false), '');
  f = f.replaceAll(RegExp(r'(MT|PS|PSMT)$'), '');
  final l = f.toLowerCase();
  if (l.isEmpty) return 'Calibri';
  if (l.startsWith('helvetica') || l == 'arial') return 'Arial';
  if (l.startsWith('times')) return 'Times New Roman';
  if (l.startsWith('courier')) return 'Courier New';
  if (l.contains('freesans')) return 'Arial';
  return f.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
}
