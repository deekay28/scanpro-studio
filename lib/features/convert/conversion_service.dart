import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../pdf/pdf_service.dart' show PdfService;
import '../pdf_editor/engine/engine_worker.dart';
import '../pdf_editor/engine/pdfium_engine.dart' show PageImage, RasterFormat;
import 'doc_to_pdf.dart';
import 'layout/layout_docx.dart';
import 'layout/layout_model.dart';
import 'layout/layout_check.dart';
import 'layout/native_layout.dart';
import 'layout/ocr_review.dart';
import 'layout/scan_analysis.dart';
import 'model/page_content.dart';
import 'office_conversions.dart';
import 'ooxml/docx.dart';
import 'ooxml/pptx.dart';
import 'ooxml/xlsx.dart';
import 'pdf_to_doc.dart';
import 'table_extraction.dart';

/// Every conversion the Conversion Centre offers.
enum ConversionType {
  pdfToDocx('PDF to Word', ['pdf'], 'docx'),
  pdfToXlsx('PDF to Excel', ['pdf'], 'xlsx'),
  pdfToPptx('PDF to PowerPoint', ['pdf'], 'pptx'),
  pdfToImages('PDF to images', ['pdf'], 'jpg'),
  pdfToText('PDF to text', ['pdf'], 'txt'),
  pdfToHtml('PDF to HTML', ['pdf'], 'html'),
  pdfToCsv('PDF to CSV', ['pdf'], 'csv'),
  imagesToPdf('Images to PDF', ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'tif', 'tiff'], 'pdf'),
  docxToPdf('Word to PDF', ['docx'], 'pdf'),
  xlsxToPdf('Excel to PDF', ['xlsx'], 'pdf'),
  pptxToPdf('PowerPoint to PDF', ['pptx'], 'pdf'),
  pptxToXlsx('PowerPoint to Excel', ['pptx'], 'xlsx'),
  xlsxToPptx('Excel to PowerPoint', ['xlsx'], 'pptx'),
  htmlToPdf('HTML to PDF', ['html', 'htm'], 'pdf'),
  textToPdf('Text to PDF', ['txt', 'md', 'csv', 'log'], 'pdf');

  final String label;
  final List<String> sources;
  final String target;
  const ConversionType(this.label, this.sources, this.target);

  bool get fromPdf => sources.contains('pdf');
  bool get combinesInputs => this == imagesToPdf;
}

enum ImageQuality { low, standard, high, print }

/// How PDF → Word rebuilds pages.
enum DocxMode {
  /// Scanned pages as page images, digital pages as editable text.
  automatic,

  /// Every page as one page-sized picture: looks like the original, text
  /// is not editable.
  faithful,

  /// Real Word text, tables and pictures at their original positions
  /// (OCR for scanned pages).
  editable,
}

/// Options for one job. Only the options that apply to the job's type are
/// used; the UI shows just those.
class ConversionOptions {
  final String pageRange; // "1-3, 5" (1-based); empty = all
  final bool ocr; // run OCR on scanned pages
  final String ocrScript; // latin | devanagari
  final DocxMode docxMode;
  final double pageDpi; // faithful pages (when the page must be rendered)
  final bool markUncertain; // highlight words read with low OCR confidence
  final bool pptxEditable;
  final bool sheetPerPage; // PDF→XLSX: one sheet per page instead of per table
  final bool allTextIfNoTable; // PDF→XLSX: export lines when no table is found
  final RasterFormat imageFormat;
  final double dpi;
  final int jpegQuality;
  final bool grayscale;
  final bool zip; // pack images into one ZIP
  final String fileNameTemplate; // {name}, {n}
  final String cellRange; // XLSX→PDF/PPTX: "A1:D20"
  final String slideRange; // PPTX→PDF/XLSX: "1-3"
  final bool charts; // XLSX→PPTX: add chart slides
  final bool fitToA4; // images→PDF: A4 pages instead of image size
  final bool extractTables;
  final bool extractCharts;
  final bool extractText;
  final bool slideSheets; // PPTX→XLSX: one text sheet per slide

  const ConversionOptions({
    this.pageRange = '',
    this.ocr = true,
    this.ocrScript = 'latin',
    this.docxMode = DocxMode.automatic,
    this.pageDpi = 300,
    this.markUncertain = false,
    this.pptxEditable = false,
    this.sheetPerPage = false,
    this.allTextIfNoTable = true,
    this.imageFormat = RasterFormat.jpg,
    this.dpi = 150,
    this.jpegQuality = 85,
    this.grayscale = false,
    this.zip = false,
    this.fileNameTemplate = '{name}_page{n}',
    this.cellRange = '',
    this.slideRange = '',
    this.charts = true,
    this.fitToA4 = true,
    this.extractTables = true,
    this.extractCharts = true,
    this.extractText = true,
    this.slideSheets = false,
  });

  Map<String, dynamic> toJson() => {
        'pr': pageRange,
        'ocr': ocr,
        'os': ocrScript,
        'dm': docxMode.name,
        'pd': pageDpi,
        'mu': markUncertain,
        'pe': pptxEditable,
        'spp': sheetPerPage,
        'at': allTextIfNoTable,
        'if': imageFormat.name,
        'dpi': dpi,
        'q': jpegQuality,
        'g': grayscale,
        'z': zip,
        'ft': fileNameTemplate,
        'cr': cellRange,
        'sr': slideRange,
        'ch': charts,
        'a4': fitToA4,
        'et': extractTables,
        'ec': extractCharts,
        'ex': extractText,
        'ss': slideSheets,
      };

  factory ConversionOptions.fromJson(Map<String, dynamic> j) => ConversionOptions(
        pageRange: j['pr'] as String? ?? '',
        ocr: j['ocr'] as bool? ?? true,
        ocrScript: j['os'] as String? ?? 'latin',
        docxMode: DocxMode.values.firstWhere((e) => e.name == j['dm'], orElse: () => DocxMode.automatic),
        pageDpi: (j['pd'] as num?)?.toDouble() ?? 300,
        markUncertain: j['mu'] as bool? ?? false,
        pptxEditable: j['pe'] as bool? ?? false,
        sheetPerPage: j['spp'] as bool? ?? false,
        allTextIfNoTable: j['at'] as bool? ?? true,
        imageFormat: RasterFormat.values.firstWhere((e) => e.name == j['if'], orElse: () => RasterFormat.jpg),
        dpi: (j['dpi'] as num?)?.toDouble() ?? 150,
        jpegQuality: (j['q'] as num?)?.toInt() ?? 85,
        grayscale: j['g'] as bool? ?? false,
        zip: j['z'] as bool? ?? false,
        fileNameTemplate: j['ft'] as String? ?? '{name}_page{n}',
        cellRange: j['cr'] as String? ?? '',
        slideRange: j['sr'] as String? ?? '',
        charts: j['ch'] as bool? ?? true,
        fitToA4: j['a4'] as bool? ?? true,
        extractTables: j['et'] as bool? ?? true,
        extractCharts: j['ec'] as bool? ?? true,
        extractText: j['ex'] as bool? ?? true,
        slideSheets: j['ss'] as bool? ?? false,
      );
}

/// An output file of a job.
class ConversionOutput {
  final String path; // absolute
  final String name;
  final int size;
  const ConversionOutput(this.path, this.name, this.size);
  Map<String, dynamic> toJson() => {'p': path, 'n': name, 's': size};
  factory ConversionOutput.fromJson(Map<String, dynamic> j) => ConversionOutput(j['p'] as String, j['n'] as String, (j['s'] as num).toInt());
}

class CancelToken {
  bool cancelled = false;
  void check() {
    if (cancelled) throw const ConversionCancelled();
  }
}

class ConversionCancelled implements Exception {
  const ConversionCancelled();
  @override
  String toString() => 'Cancelled';
}

/// Recognises text on a rendered page image. Returns words in pixel
/// coordinates of the image (the app uses on-device ML Kit).
typedef OcrRecognizer = Future<List<PdfWord>> Function(Uint8List png, int width, int height, String script);

typedef PasswordFor = Future<String?> Function(String fileName, bool wrong);

class ConversionResult {
  final List<ConversionOutput> outputs;
  final List<String> warnings;
  const ConversionResult(this.outputs, this.warnings);
}

/// Runs conversions. PDF work goes through the shared PDFium host; heavy
/// pure-Dart encoding runs in background isolates.
class ConversionService {
  final Uint8List unicodeFont;
  final OcrRecognizer? ocr;
  ConversionService({required this.unicodeFont, this.ocr});

  Future<PdfiumHost> get _host => PdfiumHost.start(unicodeFont);

  /// Converts [inputs] (absolute paths) into files in [outDir].
  Future<ConversionResult> run(
    ConversionType type,
    List<(String path, String name, String? password)> inputs,
    ConversionOptions o,
    String outDir,
    String outputName, {
    void Function(double progress, String message)? onProgress,
    CancelToken? cancel,
  }) async {
    final token = cancel ?? CancelToken();
    void progress(double v, String m) => onProgress?.call(v.clamp(0, 1).toDouble(), m);
    await Directory(outDir).create(recursive: true);
    final warnings = <String>[];
    final outputs = <ConversionOutput>[];

    Future<ConversionOutput> write(String fileName, Uint8List bytes) async {
      final name = uniqueName(outDir, fileName);
      final tmp = File(p.join(outDir, '$name.part'));
      try {
        await tmp.writeAsBytes(bytes, flush: true);
      } on FileSystemException catch (e) {
        if (await tmp.exists()) await tmp.delete();
        if ((e.osError?.errorCode ?? 0) == 28) throw const FileSystemException('Not enough storage space');
        rethrow;
      }
      await validateOutput(name, bytes);
      final f = await tmp.rename(p.join(outDir, name));
      final o = ConversionOutput(f.path, name, bytes.length);
      outputs.add(o);
      return o;
    }

    if (type == ConversionType.imagesToPdf) {
      progress(0, 'Reading images…');
      final images = <Uint8List>[];
      for (final (path, _, _) in inputs) {
        token.check();
        images.add(await File(path).readAsBytes());
      }
      final pdf = await compute(_work, ('images', [images, o.fitToA4])) as Uint8List;
      await write('$outputName.pdf', pdf);
      progress(1, 'Done');
      return ConversionResult(outputs, warnings);
    }

    for (var fi = 0; fi < inputs.length; fi++) {
      token.check();
      final (path, name, password) = inputs[fi];
      final base = inputs.length == 1 ? outputName : p.basenameWithoutExtension(name);
      double sub(double v) => (fi + v) / inputs.length;
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) throw FormatException('$name is empty.');
      final fileWarnings = <String>[];
      switch (type) {
        case ConversionType.docxToPdf:
          progress(sub(0.2), 'Reading $name…');
          final pdf = await compute(_work, ('docx', [bytes, unicodeFont])) as Uint8List;
          await write('$base.pdf', pdf);
          fileWarnings.add('Word layout is approximated: fonts are replaced by standard PDF fonts and complex layout (columns, text boxes, shapes) is simplified.');
        case ConversionType.xlsxToPdf:
          final pdf = await compute(_work, ('xlsx', [bytes, unicodeFont, o.cellRange, base])) as Uint8List;
          await write('$base.pdf', pdf);
        case ConversionType.pptxToPdf:
          final pdf = await compute(_work, ('pptx', [bytes, unicodeFont, o.slideRange])) as Uint8List;
          await write('$base.pdf', pdf);
          fileWarnings.add('Slides are re-drawn from their content: animations, theme backgrounds, shapes other than text, pictures, tables and bar charts are not reproduced.');
        case ConversionType.pptxToXlsx:
          final r = await compute(_work, ('pptx2xlsx', [bytes, o.toJson(), base])) as (Uint8List, List<String>);
          fileWarnings.addAll(r.$2);
          await write('$base.xlsx', r.$1);
        case ConversionType.xlsxToPptx:
          final pptx = await compute(_work, ('xlsx2pptx', [bytes, base, o.cellRange, o.charts])) as Uint8List;
          await write('$base.pptx', pptx);
        case ConversionType.htmlToPdf:
          final r = await compute(_work, ('html', [bytes, unicodeFont, base])) as (Uint8List, List<String>);
          fileWarnings.addAll(r.$2);
          fileWarnings.add('Only basic HTML is supported (headings, paragraphs, lists, tables, emphasis, links, embedded images); CSS layout and scripts are ignored.');
          await write('$base.pdf', r.$1);
        case ConversionType.textToPdf:
          final pdf = await compute(_work, ('text', [bytes, unicodeFont, base])) as Uint8List;
          await write('$base.pdf', pdf);
        default:
          await _fromPdf(type, bytes, name, password, base, o, write, fileWarnings, (v, m) => progress(sub(v), m), token);
      }
      warnings.addAll(inputs.length > 1 ? fileWarnings.map((w) => '$name: $w') : fileWarnings);
    }
    progress(1, 'Done');
    return ConversionResult(outputs, warnings);
  }

  Future<void> _fromPdf(ConversionType type, Uint8List bytes, String name, String? password, String base, ConversionOptions o,
      Future<ConversionOutput> Function(String, Uint8List) write, List<String> warnings, void Function(double, String) progress, CancelToken token) async {
    final host = await _host;
    final s = await host.open(bytes, password: password);
    try {
      final pages = o.pageRange.trim().isEmpty ? [for (var i = 0; i < s.pageCount; i++) i] : PdfService.parseRanges(o.pageRange, s.pageCount).expand((e) => e).toSet().toList();
      if (type == ConversionType.pdfToImages) {
        final ext = switch (o.imageFormat) { RasterFormat.jpg => 'jpg', RasterFormat.png => 'png', RasterFormat.tiff => 'tif' };
        final archive = o.zip ? Archive() : null;
        for (var k = 0; k < pages.length; k++) {
          token.check();
          progress(k / pages.length, 'Rendering page ${pages[k] + 1} of ${s.pageCount}…');
          final data = await s.call<Uint8List>('renderEncoded', [pages[k], o.dpi, o.imageFormat.index, o.jpegQuality, o.grayscale]);
          final fname = '${o.fileNameTemplate.replaceAll('{name}', base).replaceAll('{n}', '${pages[k] + 1}'.padLeft(s.pageCount.toString().length, '0'))}.$ext';
          if (archive != null) {
            archive.addFile(ArchiveFile(fname, data.length, data));
          } else {
            await write(fname, data);
          }
        }
        if (archive != null) await write('$base.zip', Uint8List.fromList(ZipEncoder().encode(archive)!));
        return;
      }
      if (type == ConversionType.pdfToDocx) {
        await _pdfToDocx(s, pages, base, o, write, warnings, progress, token);
        return;
      }
      // Structured content, with OCR for scanned pages.
      final needImages = type == ConversionType.pdfToDocx || type == ConversionType.pdfToHtml || (type == ConversionType.pdfToPptx && o.pptxEditable);
      final pageImages = <int, ({Uint8List bytes})>{};
      final (contents, ocrSkipped) = await _pdfContents(type, s, pages, o, needImages, pageImages, warnings, progress, token);
      token.check();
      progress(0.85, 'Writing file…');
      switch (type) {
        case ConversionType.pdfToHtml:
          final r = await compute(_work, ('pdf2html', [contents, base])) as (Uint8List, List<String>);
          warnings.addAll(r.$2);
          await write('$base.html', r.$1);
        case ConversionType.pdfToText:
          final text = pagesToText(contents);
          if (text.trim().isEmpty) {
            throw FormatException(ocrSkipped > 0 ? 'No text was found: the pages are scans. Turn on OCR to recognise their text.' : 'No text was found on the selected pages.');
          }
          await write('$base.txt', utf8Bytes(text));
          warnings.addAll(contentWarnings(contents));
        case ConversionType.pdfToXlsx || ConversionType.pdfToCsv:
          final tables = await _tablesFor(contents, o, warnings);
          if (type == ConversionType.pdfToXlsx) {
            final x = await compute(_work, ('tables2xlsx', [tables, o.sheetPerPage, base])) as Uint8List;
            await write('$base.xlsx', x);
          } else {
            for (var i = 0; i < tables.length; i++) {
              final csv = tableToCsv([for (final r in tables[i].rows) [for (final c in r) c.text]]);
              await write(tables.length == 1 ? '$base.csv' : '${base}_page${tables[i].page + 1}_table${i + 1}.csv', utf8Bytes('﻿$csv'));
            }
          }
        case ConversionType.pdfToPptx:
          if (o.pptxEditable) {
            final r = await compute(_work, ('pdf2pptx', [contents, base, pageImages])) as (Uint8List, List<int>);
            if (r.$2.isNotEmpty) warnings.add('Slides ${r.$2.join(', ')} come from scanned pages and are pictures, not editable text.');
            warnings.addAll(contentWarnings(contents).where((w) => !w.contains('OCR')));
            await write('$base.pptx', r.$1);
          } else {
            final slides = <(Uint8List, Size)>[];
            for (var k = 0; k < pages.length; k++) {
              token.check();
              progress(0.85 + 0.1 * k / pages.length, 'Rendering slide ${k + 1}…');
              slides.add((await s.call<Uint8List>('renderEncoded', [pages[k], o.dpi, RasterFormat.jpg.index, o.jpegQuality, false]), contents[k].size));
            }
            final pptx = await compute(_work, ('visualSlides', [slides, base])) as Uint8List;
            warnings.add('Visual slides are page images: they look like the PDF but their text is not editable. Choose "Editable" for text boxes.');
            await write('$base.pptx', pptx);
          }
        default:
          throw StateError('Unsupported conversion $type');
      }
    } finally {
      s.close();
    }
  }

  /// PDF → Word. Each source page becomes one Word page of the same size:
  /// - faithful: the page as one picture (the scan's own JPEG when the page
  ///   is just a photo, otherwise rendered at [ConversionOptions.pageDpi]);
  /// - editable: a digital page's own text, fonts, tables and images at
  ///   their positions; a scanned page straightened and analysed (OCR,
  ///   ruling lines, tables, shading, stamps/QR codes/signatures as
  ///   pictures) and rebuilt with real text;
  /// - automatic: scanned pages faithful, digital pages editable.
  Future<void> _pdfToDocx(HostSession s, List<int> pages, String base, ConversionOptions o, Future<ConversionOutput> Function(String, Uint8List) write,
      List<String> warnings, void Function(double, String) progress, CancelToken token) async {
    final out = <LayoutPage>[];
    var asImage = 0, rebuiltDigital = 0, noOcr = 0;
    for (var k = 0; k < pages.length; k++) {
      token.check();
      final pi = pages[k];
      final label = 'page ${pi + 1} of ${s.pageCount}';
      progress(k / pages.length * 0.9, 'Reading $label…');
      final c = await s.call<PageContent>('content', [pi, true]);
      var faithful = o.docxMode == DocxMode.faithful || (o.docxMode == DocxMode.automatic && c.scanned);
      if (!faithful && c.scanned && (ocr == null || !o.ocr)) {
        faithful = true;
        noOcr++;
      }
      if (faithful) {
        progress(k / pages.length * 0.9, 'Copying $label as an image…');
        final im = await s.call<PageImage>('pageImage', [pi, o.pageDpi, math.max(o.jpegQuality, 90), false, true]);
        out.add(LayoutPage(c.size, background: LGraphic(im.box, im.bytes, im.ext, im.width, im.height, kind: GraphicKind.pageImage)));
        asImage++;
        continue;
      }
      if (!c.scanned) {
        final page = await compute(_work, ('nativeLayout', [c])) as LayoutPage;
        for (final pr in checkLayout(page).problems) {
          warnings.add('Page ${pi + 1}: check the layout: $pr.');
        }
        out.add(page);
        rebuiltDigital++;
        continue;
      }
      // Scanned page: analyse the photo at its own resolution.
      progress(k / pages.length * 0.9, 'Straightening $label…');
      final im = await s.call<PageImage>('pageImage', [pi, 200.0, 90, false, true]);
      var scale = im.original ? im.width / im.box.width : 200 / 72;
      scale = math.min(scale, 2600 / math.max(c.size.width, c.size.height));
      final r = await s.call<RenderedPage>('renderOriginal', [pi, scale]);
      final box = im.original ? im.box : Offset.zero & c.size;
      final (rgba, w, h) = cropRgba(r.rgba, r.width, r.height, Rect.fromLTRB(box.left * scale, box.top * scale, box.right * scale, box.bottom * scale));
      final prep = await compute(_work, ('prepareScan', [rgba, w, h, box])) as PreparedScan;
      token.check();
      progress(k / pages.length * 0.9, 'Recognising text on $label…');
      final words = await ocr!(prep.png, prep.rectified.width, prep.rectified.height, o.ocrScript);
      token.check();
      progress(k / pages.length * 0.9, 'Rebuilding the layout of $label…');
      var page = await compute(_work, ('scanLayout', [prep, words, c.size])) as LayoutPage;
      // Second pass: text the OCR engine skipped (often table cells) is read
      // again region by region, enlarged.
      if (page.unread.isNotEmpty) {
        progress(k / pages.length * 0.9, 'Reading ${page.unread.length} missed area(s) on $label…');
        final more = await _readRegions(prep, page.unread, o.ocrScript, token);
        if (more.isNotEmpty) page = await compute(_work, ('scanLayout', [prep, [...words, ...more], c.size])) as LayoutPage;
      }
      for (final w in page.warnings) {
        warnings.add('Page ${pi + 1}: $w');
      }
      final kinds = page.graphics.map((g) => g.kind).toList();
      final cov = checkLayout(page);
      warnings.add('Page ${pi + 1} (scan) rebuilt as editable text (OCR): ${cov.summary}'
          '${kinds.isEmpty ? '' : ' (pictures: ${kinds.map((k) => _kindName(k)).join(', ')})'}. Fonts are estimated from the scan (Arial); bold text is detected from stroke width and may be missed.');
      for (final pr in cov.problems) {
        warnings.add('Page ${pi + 1}: check the layout: $pr.');
      }
      if (page.unreadInTables.isNotEmpty) {
        warnings.add('Page ${pi + 1}: ${page.unreadInTables.length} mark(s) in table cells could not be read (a lone digit, for example); '
            'the cell is left empty. They are listed in "Review OCR words"; check them against the original.');
      }
      out.add(page);
    }
    token.check();
    progress(0.92, 'Writing the Word file…');
    final (docx, reviewJson, toCheck) = await compute(_work, ('layoutDocx', [out, base, o.markUncertain])) as (Uint8List, String, int);
    if (asImage > 0) {
      warnings.add('$asImage page(s) were kept as page images (${o.docxMode == DocxMode.automatic ? 'Automatic: scanned pages' : 'Faithful layout'}). '
          'They look like the original, but their text is a picture and cannot be edited in Word. Choose "Editable document" to rebuild them as text.');
    }
    if (noOcr > 0) warnings.add('$noOcr scanned page(s) were kept as images because OCR is off or not available.');
    if (rebuiltDigital > 0) {
      warnings.add('$rebuiltDigital digital page(s) rebuilt with their own text, fonts, tables and images at their original positions. '
          'Fonts that are not installed where the file is opened are replaced by similar ones.');
    }
    final written = await write('$base.docx', docx);
    if (toCheck > 0 || reviewJson.contains('"omitted":true')) {
      // Kept beside the document (not an output): the review screen lists
      // these words and writes corrections into the document.
      await File(reviewPathFor(written.path)).writeAsString(reviewJson);
      if (toCheck > 0) {
        warnings.add('$toCheck word(s) were read with low OCR confidence. They are not highlighted in the document; use "Review OCR words" in the file\'s menu to check and correct them.');
      }
    }
  }

  /// OCR on parts of a prepared scan; words come back in the scan's pixels.
  Future<List<PdfWord>> _readRegions(PreparedScan prep, List<Rect> regions, String script, CancelToken token) async {
    final full = prep.rectified;
    final out = <PdfWord>[];
    for (final r in regions) {
      token.check();
      final x0 = r.left.floor().clamp(0, full.width - 1), y0 = r.top.floor().clamp(0, full.height - 1);
      final cw = (r.right.ceil() - x0).clamp(1, full.width - x0), ch = (r.bottom.ceil() - y0).clamp(1, full.height - y0);
      final k = ch < 60 ? 2 : 1; // small text reads better enlarged
      final m = (ch / 2).round(); // and with a white margin around it
      final png = await compute(_cropPng, (full.data, full.width, x0, y0, cw, ch, k, m));
      final words = await ocr!(png, (cw + 2 * m) * k, (ch + 2 * m) * k, script);
      for (final wd in words) {
        final b = wd.box;
        final box = Rect.fromLTRB(x0 + b.left / k - m, y0 + b.top / k - m, x0 + b.right / k - m, y0 + b.bottom / k - m);
        // Words read twice are resolved after word boxes are taken from the
        // ink (InkGeometry keeps the more confident reading).
        // Line ids of each region are kept apart from the first pass's.
        // Regions can be marks rather than text: only words read with
        // confidence that contain a letter or digit are taken.
        final real = (wd.confidence ?? 0.8) >= 0.6 && RegExp(r'[A-Za-z0-9\u0900-\u097F]').hasMatch(wd.text);
        if (real) out.add(PdfWord(wd.text, box, confidence: wd.confidence, line: wd.line == null ? null : (regions.indexOf(r) + 1) * 100000 + wd.line!));
      }
    }
    return out;
  }

  /// Reads the structured content of [pages], running OCR on scanned pages
  /// when allowed. Returns the contents and the number of scanned pages whose
  /// text could not be recognised.
  Future<(List<PageContent>, int)> _pdfContents(ConversionType type, HostSession s, List<int> pages, ConversionOptions o, bool needImages,
      Map<int, ({Uint8List bytes})> pageImages, List<String> warnings, void Function(double, String) progress, CancelToken token) async {
    final contents = <PageContent>[];
    var ocrSkipped = 0;
    for (var k = 0; k < pages.length; k++) {
      token.check();
      progress(k / pages.length * 0.8, 'Reading page ${pages[k] + 1} of ${s.pageCount}…');
      var c = await s.call<PageContent>('content', [pages[k], needImages]);
      if (c.scanned) {
        if (o.ocr && ocr != null && type != ConversionType.pdfToPptx) {
          progress(k / pages.length * 0.8, 'Recognising text on page ${pages[k] + 1}…');
          c = await _ocrPage(s, c, o.ocrScript);
        } else if (type != ConversionType.pdfToPptx) {
          ocrSkipped++;
        }
        if (type == ConversionType.pdfToPptx && o.pptxEditable) {
          pageImages[pages[k]] = (bytes: await s.call<Uint8List>('renderEncoded', [pages[k], o.dpi, RasterFormat.jpg.index, o.jpegQuality, false]));
        }
      }
      contents.add(c);
    }
    if (ocrSkipped > 0) warnings.add('$ocrSkipped scanned page(s) have no text layer; ${ocr == null ? 'OCR is not available here' : 'turn on OCR'} to convert their text.');
    return (contents, ocrSkipped);
  }

  /// Extracts tables for review before export (PDF → Excel/CSV and
  /// PowerPoint → Excel). The sheets can be corrected and then written with
  /// [writeXlsx] or [tableToCsv].
  Future<(List<Sheet>, List<String>)> previewSheets(ConversionType type, String path, String? password, ConversionOptions o,
      {void Function(double, String)? onProgress, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    void progress(double v, String m) => onProgress?.call(v.clamp(0, 1).toDouble(), m);
    final bytes = await File(path).readAsBytes();
    if (type == ConversionType.pptxToXlsx) {
      progress(0.3, 'Reading slides…');
      return await compute(_work, ('pptxSheets', [bytes, o.toJson()])) as (List<Sheet>, List<String>);
    }
    final warnings = <String>[];
    final s = await (await _host).open(bytes, password: password);
    try {
      final pages = o.pageRange.trim().isEmpty ? [for (var i = 0; i < s.pageCount; i++) i] : PdfService.parseRanges(o.pageRange, s.pageCount).expand((e) => e).toSet().toList();
      final (contents, _) = await _pdfContents(type, s, pages, o, false, {}, warnings, progress, token);
      token.check();
      progress(0.85, 'Finding tables…');
      final tables = await _tablesFor(contents, o, warnings);
      return (tablesToSheets(tables, perPage: o.sheetPerPage), warnings);
    } finally {
      s.close();
    }
  }

  Future<List<ExtractedTable>> _tablesFor(List<PageContent> contents, ConversionOptions o, List<String> warnings) async {
    var tables = await compute(_work, ('tables', [contents])) as List<ExtractedTable>;
    if (tables.isEmpty && o.allTextIfNoTable) {
      warnings.add('No table was detected; every text line was exported as a row instead.');
      tables = [
        for (final c in contents)
          ExtractedTable(c.index, Offset.zero & c.size, [
            for (final l in c.lines) [parseCell(l.text)]
          ], 'text lines')
      ];
    } else if (tables.isEmpty) {
      throw const FormatException('No tables were found on the selected pages.');
    }
    final uncertain = tables.fold<int>(0, (n, t) => n + t.uncertainCells);
    if (uncertain > 0) warnings.add('$uncertain cell(s) look misread or have low OCR confidence; they are highlighted and kept as text.');
    warnings.add('Tables are detected automatically; check merged cells and column boundaries.');
    return tables;
  }

  Future<PageContent> _ocrPage(HostSession s, PageContent c, String script) async {
    const scale = 2.5;
    final png = await s.call<Uint8List>('renderEncoded', [c.index, 72 * scale, RasterFormat.png.index, 90, false]);
    final dims = img.findDecoderForData(png)?.startDecode(png);
    final words = await ocr!(png, dims?.width ?? 0, dims?.height ?? 0, script);
    final pts = [
      for (final w in words)
        PdfWord(w.text, Rect.fromLTRB(w.box.left / scale, w.box.top / scale, w.box.right / scale, w.box.bottom / scale),
            size: math.max(4, w.box.height / scale * 0.85), confidence: w.confidence),
    ];
    return PageContent(index: c.index, size: c.size, lines: groupWordsIntoLines(pts), images: const [], fromOcr: true);
  }
}

/// Background work (runs in a fresh isolate via [compute]; only the
/// explicit arguments are sent).
Object _work((String, List<Object?>) msg) {
  final (op, a) = msg;
  switch (op) {
    case 'images':
      return imagesToPdf((a[0] as List).cast<Uint8List>(), fitToA4: a[1] as bool);
    case 'docx':
      return DocPdfRenderer(a[1] as Uint8List).render(readDocx(a[0] as Uint8List));
    case 'xlsx':
      final range = a[2] as String;
      return DocPdfRenderer(a[1] as Uint8List).render(sheetsToDoc(readXlsx(a[0] as Uint8List), range: range.isEmpty ? null : range, title: a[3] as String));
    case 'pptx':
      final deck = readPptx(a[0] as Uint8List);
      final slides = a[2] as String;
      final only = slides.trim().isEmpty ? null : PdfService.parseRanges(slides, deck.slides.length).expand((e) => e).toList();
      return slidesToPdf(deck, a[1] as Uint8List, only: only);
    case 'pptx2xlsx':
      final o = ConversionOptions.fromJson((a[1] as Map).cast<String, dynamic>());
      final deck = readPptx(a[0] as Uint8List);
      final only = o.slideRange.trim().isEmpty ? null : PdfService.parseRanges(o.slideRange, deck.slides.length).expand((e) => e).toList();
      final res = pptxToSheets(deck, o: PptxExtractOptions(slides: only, tables: o.extractTables, charts: o.extractCharts, text: o.extractText, sheetPerSlide: o.slideSheets));
      return (writeXlsx(res.sheets, title: a[2] as String), res.notes);
    case 'xlsx2pptx':
      final range = a[2] as String;
      return writePptx(sheetsToDeck(readXlsx(a[0] as Uint8List), title: a[1] as String, range: range.isEmpty ? null : range, charts: a[3] as bool));
    case 'html':
      final h = htmlToDoc(utf8.decode(a[0] as Uint8List, allowMalformed: true), title: a[2] as String);
      return (DocPdfRenderer(a[1] as Uint8List).render(h.doc), h.notes);
    case 'text':
      return DocPdfRenderer(a[1] as Uint8List).render(textToDoc(utf8.decode(a[0] as Uint8List, allowMalformed: true), title: a[2] as String));
    case 'layoutDocx':
      final pages = (a[0] as List).cast<LayoutPage>();
      final review = <OcrReviewItem>[];
      final docx = writeLayoutDocx(pages, title: a[1] as String, highlightUncertain: a[2] as bool, review: review);
      return (docx, encodeReview(review, [for (final p in pages) p.size]), review.where((x) => !x.omitted).length);
    case 'prepareScan':
      return prepareScan(a[0] as Uint8List, a[1] as int, a[2] as int, a[3] as Rect);
    case 'scanLayout':
      return buildScanLayout(a[0] as PreparedScan, (a[1] as List).cast<PdfWord>(), a[2] as Size);
    case 'nativeLayout':
      return nativeLayout(a[0] as PageContent);
    case 'pdf2html':
      final b = buildDoc((a[0] as List).cast<PageContent>(), title: a[1] as String);
      return (utf8Bytes(docToHtml(b.doc)), b.warnings);
    case 'tables':
      const svc = TableExtractionService();
      return [for (final c in (a[0] as List).cast<PageContent>()) ...svc.extract(c)];
    case 'pptxSheets':
      final o = ConversionOptions.fromJson((a[1] as Map).cast<String, dynamic>());
      final deck = readPptx(a[0] as Uint8List);
      final only = o.slideRange.trim().isEmpty ? null : PdfService.parseRanges(o.slideRange, deck.slides.length).expand((e) => e).toList();
      final res = pptxToSheets(deck, o: PptxExtractOptions(slides: only, tables: o.extractTables, charts: o.extractCharts, text: o.extractText, sheetPerSlide: o.slideSheets));
      return (res.sheets, res.notes);
    case 'tables2xlsx':
      return writeXlsx(tablesToSheets((a[0] as List).cast<ExtractedTable>(), perPage: a[1] as bool), title: a[2] as String);
    case 'pdf2pptx':
      final res = pagesToEditableSlides((a[0] as List).cast<PageContent>(), title: a[1] as String, pageImages: (a[2] as Map).cast<int, ({Uint8List bytes})>());
      return (writePptx(res.deck), res.imageSlides);
    case 'visualSlides':
      final slides = (a[0] as List).cast<(Uint8List, Size)>();
      final first = slides.first.$2;
      const w = 720.0;
      final h = (w * first.height / first.width).clamp(72.0, 4032.0);
      return writePptx(PresentationModel([
        for (final (im, size) in slides)
          () {
            final k = math.min(w / size.width, h / size.height);
            final sw = size.width * k, sh = size.height * k;
            return SlideModel([SlidePicture(Rect.fromLTWH((w - sw) / 2, (h - sh) / 2, sw, sh), im, label: 'Page image')]);
          }(),
      ], width: w, height: h, title: a[1] as String));
    default:
      throw StateError('Unknown work $op');
  }
}

String _kindName(GraphicKind k) => switch (k) {
      GraphicKind.qrCode => 'QR code',
      GraphicKind.stamp => 'stamp or seal',
      GraphicKind.signature => 'signature',
      GraphicKind.photo => 'photo',
      GraphicKind.logo => 'logo',
      GraphicKind.pageImage => 'page image',
      GraphicKind.graphic => 'graphic',
    };

/// A region of an RGB image as PNG with a white margin of [m] pixels,
/// enlarged [k] times.
Uint8List _cropPng((Uint8List, int, int, int, int, int, int, int) a) {
  final (data, width, x0, y0, cw, ch, k, m) = a;
  var im = img.Image(width: cw + 2 * m, height: ch + 2 * m, numChannels: 3)..clear(img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      final j = ((y0 + y) * width + x0 + x) * 3;
      im.setPixelRgb(x + m, y + m, data[j], data[j + 1], data[j + 2]);
    }
  }
  if (k > 1) im = img.copyResize(im, width: im.width * k, height: im.height * k, interpolation: img.Interpolation.cubic);
  return Uint8List.fromList(img.encodePng(im, level: 1));
}

/// Image files → PDF, one page per image (A4 with the image fitted, or a
/// page the size of the image at 150 dpi).
Uint8List imagesToPdf(List<Uint8List> images, {bool fitToA4 = true}) {
  final doc = sf.PdfDocument();
  try {
    doc.pageSettings.margins.all = 0;
    for (final raw in images) {
      var data = raw;
      final isJpegOrPng = (raw.length > 2 && raw[0] == 0xFF && raw[1] == 0xD8) || (raw.length > 4 && raw[0] == 0x89 && raw[1] == 0x50);
      if (!isJpegOrPng) {
        final im = img.decodeImage(raw);
        if (im == null) throw const FormatException('One of the images could not be read.');
        data = Uint8List.fromList(img.encodeJpg(im, quality: 92));
      }
      final bmp = sf.PdfBitmap(data);
      final iw = bmp.width.toDouble(), ih = bmp.height.toDouble();
      final land = iw > ih;
      final Size size = fitToA4 ? (land ? const Size(841.89, 595.28) : const Size(595.28, 841.89)) : Size(iw * 72 / 150, ih * 72 / 150);
      final section = doc.sections!.add();
      section.pageSettings.margins.all = 0;
      section.pageSettings.orientation = land ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;
      section.pageSettings.size = size;
      final page = section.pages.add();
      final margin = fitToA4 ? 18.0 : 0.0;
      final k = math.min((size.width - 2 * margin) / iw, (size.height - 2 * margin) / ih);
      final w = iw * k, h = ih * k;
      page.graphics.drawImage(bmp, Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h));
    }
    return Uint8List.fromList(doc.saveSync());
  } finally {
    doc.dispose();
  }
}

/// A file name that does not exist yet in [dir].
String uniqueName(String dir, String name) {
  var clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  if (clean.isEmpty) clean = 'output';
  bool taken(String n) => FileSystemEntity.typeSync(p.join(dir, n)) != FileSystemEntityType.notFound || File(p.join(dir, '$n.part')).existsSync();
  if (!taken(clean)) return clean;
  final ext = p.extension(clean), stem = p.basenameWithoutExtension(clean);
  for (var i = 2;; i++) {
    final c = '$stem ($i)$ext';
    if (!taken(c)) return c;
  }
}

/// Re-opens an output with the matching reader before it is reported as
/// created. Throws when the output is not a valid file of its type.
Future<void> validateOutput(String name, Uint8List bytes) async {
  if (bytes.isEmpty) throw FormatException('$name is empty.');
  final ext = p.extension(name).toLowerCase();
  switch (ext) {
    case '.pdf':
      if (String.fromCharCodes(bytes.take(5)) != '%PDF-') throw FormatException('$name is not a valid PDF.');
      final d = sf.PdfDocument(inputBytes: bytes);
      final n = d.pages.count;
      d.dispose();
      if (n == 0) throw FormatException('$name has no pages.');
    case '.docx':
      await compute(readDocx, bytes);
    case '.xlsx':
      final sheets = await compute(readXlsx, bytes);
      if (sheets.isEmpty) throw FormatException('$name has no worksheets.');
    case '.pptx':
      final deck = await compute(readPptx, bytes);
      if (deck.slides.isEmpty) throw FormatException('$name has no slides.');
    case '.jpg' || '.jpeg' || '.png' || '.tif' || '.tiff':
      if (img.findDecoderForData(bytes)?.startDecode(bytes) == null) throw FormatException('$name is not a valid image.');
    case '.zip':
      final a = ZipDecoder().decodeBytes(bytes);
      if (a.isEmpty) throw FormatException('$name is empty.');
    default:
      utf8.decode(bytes, allowMalformed: false);
  }
}
