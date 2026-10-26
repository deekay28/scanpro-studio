import 'dart:typed_data';
import 'dart:ui';

import '../model/edit_state.dart';

/// Engine-neutral interface of the PDF editor. The only implementation is
/// PDFium (`pdfium_engine.dart`); a commercial SDK could be plugged in here
/// without touching the editor UI or the [EditState] model.
abstract class PdfEditEngine {
  /// Opens [bytes]. Throws [EditorPasswordRequired] when a password is
  /// needed or wrong, and [EditorPermissionDenied] when the document's
  /// security settings forbid modification for that password.
  PdfEditSession open(Uint8List bytes, {String? password});
}

class EditorPasswordRequired implements Exception {
  final bool wrong;
  const EditorPasswordRequired({this.wrong = false});
  @override
  String toString() => wrong ? 'Incorrect password.' : 'This PDF is password protected.';
}

class EditorPermissionDenied implements Exception {
  @override
  String toString() =>
      'The document\'s security settings do not allow editing with this password. Open it with the owner password to edit.';
}

class PdfEditException implements Exception {
  final String message;
  const PdfEditException(this.message);
  @override
  String toString() => message;
}

/// Font facts read from the PDF for a run of text.
class FontFacts {
  final String baseName; // e.g. "ABCDEF+Calibri-Bold"
  final String family; // without subset prefix and style suffix
  final bool embedded;
  final bool subset;
  final bool bold;
  final bool italic;
  final int weight;

  const FontFacts({required this.baseName, required this.family, required this.embedded, required this.subset, required this.bold, required this.italic, required this.weight});

  String get describe => '$family${bold ? ' Bold' : ''}${italic ? ' Italic' : ''} · '
      '${embedded ? (subset ? 'embedded subset' : 'embedded') : 'not embedded'}';
}

/// One original text object.
class TextRunInfo {
  final int object; // page-object index
  final String text;
  final Rect bounds; // display points
  final Offset baseline; // origin of the first glyph (display points)
  final double size; // effective font size (points)
  final int color; // ARGB
  final FontFacts font;
  final bool upright; // not rotated/skewed relative to the displayed page
  final bool invisible; // render mode 3 (e.g. an OCR layer)

  const TextRunInfo({
    required this.object,
    required this.text,
    required this.bounds,
    required this.baseline,
    required this.size,
    required this.color,
    required this.font,
    required this.upright,
    required this.invisible,
  });
}

/// A paragraph-like group of text runs the user edits as one unit.
class TextBlockInfo {
  final int page;
  final List<TextRunInfo> runs; // reading order
  final List<List<TextRunInfo>> lines;
  final Rect bounds;
  final double leading; // baseline-to-baseline distance (points)
  final TextAlign2 align;

  const TextBlockInfo({required this.page, required this.runs, required this.lines, required this.bounds, required this.leading, required this.align});

  List<int> get objects => [for (final r in runs) r.object];
  String get key => TextBlockEdit.blockKey(page, objects);
  TextRunInfo get first => runs.first;
  bool get editableInPlace => runs.every((r) => r.upright);

  /// Text with line breaks between visual lines.
  String get text => [for (final l in lines) _joinLine(l)].join('\n');

  /// Text as one paragraph (lines joined with spaces), for reflow.
  String get flowText => [for (final l in lines) _joinLine(l)].join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _joinLine(List<TextRunInfo> line) {
    final sb = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final t = line[i].text;
      if (i > 0) {
        final gap = line[i].bounds.left - line[i - 1].bounds.right;
        final prev = line[i - 1].text;
        if (gap > line[i].size * 0.15 && !prev.endsWith(' ') && !t.startsWith(' ')) sb.write(' ');
      }
      sb.write(t);
    }
    return sb.toString();
  }

  TextStyleSpec get originalStyle => TextStyleSpec(
        font: FontChoice.original,
        size: double.parse(first.size.toStringAsFixed(2)),
        color: first.color,
        bold: first.font.bold,
        italic: first.font.italic,
        align: align,
        lineSpacing: first.size > 0 ? double.parse((leading / first.size).toStringAsFixed(3)) : 1.2,
      );
}

class ImageObjInfo {
  final int page;
  final int object;
  final Rect bounds; // display points
  final int pixelWidth;
  final int pixelHeight;
  const ImageObjInfo({required this.page, required this.object, required this.bounds, required this.pixelWidth, required this.pixelHeight});
  String get key => '$page:$object';
}

/// What the editor knows about one original page.
class PageAnalysis {
  final int page;
  final Size size; // displayed size in points
  final List<TextBlockInfo> blocks;
  final List<ImageObjInfo> images;
  final int visibleTextRuns;
  final int invisibleTextRuns;
  final double imageCoverage; // fraction of the page covered by images
  final int formObjects; // XObject forms (content not editable here)
  final int annotations;

  const PageAnalysis({
    required this.page,
    required this.size,
    required this.blocks,
    required this.images,
    required this.visibleTextRuns,
    required this.invisibleTextRuns,
    required this.imageCoverage,
    required this.formObjects,
    required this.annotations,
  });

  /// A page that is an image with no visible native text (a scan).
  bool get looksScanned => visibleTextRuns == 0 && imageCoverage > 0.5;
  bool get hasOcrLayer => invisibleTextRuns > 0;
}

/// Outcome of laying out an edited text block, shown to the user before
/// they confirm (and in the export report).
class TextEditReport {
  final String fontUsed;
  final bool originalFontUsed;
  final bool inPlace; // the original text object was rewritten in place
  final List<String> warnings;
  final Rect outBounds; // display points
  const TextEditReport({required this.fontUsed, required this.originalFontUsed, required this.inPlace, required this.warnings, required this.outBounds});
}

/// Result of export validation (re-opening the written file).
class ExportResult {
  final Uint8List bytes;
  final int pageCount;
  final List<String> warnings;
  final int annotationsBefore; // existing annotations, links and form widgets on kept pages
  final int annotationsAfter; // the same, counted again in the written file (excluding new ones)
  final bool encrypted;
  const ExportResult(this.bytes, this.pageCount, this.warnings, {this.annotationsBefore = 0, this.annotationsAfter = 0, this.encrypted = false});
}

/// Options for export.
class ExportOptions {
  final bool flattenAnnotations;
  final bool keepEncryption; // re-encrypt with the original password
  final List<int>? onlySlots; // export a subset of output pages (extract)
  const ExportOptions({this.flattenAnnotations = false, this.keepEncryption = true, this.onlySlots});
}

/// An open document in the editor. All methods are synchronous and must be
/// called from the isolate that opened it.
abstract class PdfEditSession {
  int get pageCount;
  bool get encrypted;
  String? get password;
  String? get title;

  Size pageSize(int page); // original page, displayed size
  int pageRotation(int page); // original /Rotate in degrees
  PageAnalysis analyze(int page);

  /// Renders an output page with [state] applied, or the untouched
  /// original when [original] is true. Returns RGBA pixels.
  ({Uint8List rgba, int width, int height}) render(EditState state, String slotId, double scale, {bool original = false, String draftDir = ''});

  /// Size of an output page as displayed (rotation applied).
  Size slotSize(EditState state, String slotId);

  /// Lays out an edited block without exporting, for the confirm preview.
  TextEditReport previewTextEdit(TextBlockEdit edit);

  /// Writes a new PDF with [state] applied, then re-opens it to validate.
  ExportResult export(EditState state, {ExportOptions options = const ExportOptions(), String draftDir = ''});

  void close();
}
