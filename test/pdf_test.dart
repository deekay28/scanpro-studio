import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/core/models.dart';
import 'package:scanpro_studio/core/ocr_models.dart';
import 'package:scanpro_studio/core/storage.dart';
import 'package:scanpro_studio/core/units.dart';
import 'package:scanpro_studio/features/passport/print_layout.dart';
import 'package:scanpro_studio/features/passport/sheet_renderer.dart';
import 'package:scanpro_studio/features/pdf/pdf_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

Uint8List makeTextPdf(List<String> pageTexts, {Size size = const Size(595.28, 841.89)}) {
  final doc = sf.PdfDocument();
  doc.pageSettings.margins.all = 0;
  for (final t in pageTexts) {
    final section = doc.sections!.add();
    section.pageSettings.margins.all = 0;
    section.pageSettings.orientation = size.width > size.height ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;
    section.pageSettings.size = size;
    final page = section.pages.add();
    page.graphics.drawString(t, sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 24), bounds: const Rect.fromLTWH(40, 40, 400, 40));
  }
  final bytes = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return bytes;
}

String pageText(Uint8List bytes, int i, {String? password}) {
  final doc = password == null ? sf.PdfDocument(inputBytes: bytes) : sf.PdfDocument(inputBytes: bytes, password: password);
  final t = sf.PdfTextExtractor(doc).extractText(startPageIndex: i, endPageIndex: i);
  doc.dispose();
  return t;
}

Uint8List jpeg(int w, int h, {int r = 200, int g = 180, int b = 160}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return img.encodeJpg(im, quality: 90);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PDF rebuild (merge / split / reorder / rotate / protect)', () {
    test('merge keeps order and text (no rasterisation)', () {
      final a = makeTextPdf(['Alpha one', 'Alpha two']);
      final b = makeTextPdf(['Bravo one'], size: const Size(842, 595));
      final out = PdfService.rebuild(
        [PdfSource(a), PdfSource(b)],
        const [PdfPageRef(1, 0), PdfPageRef(0, 1), PdfPageRef(0, 0)],
      );
      final info = PdfService.inspect(PdfSource(out));
      expect(info.pageCount, 3);
      expect(pageText(out, 0), contains('Bravo one'));
      expect(pageText(out, 1), contains('Alpha two'));
      expect(pageText(out, 2), contains('Alpha one'));
      // Landscape page size preserved.
      expect(info.pageSizes[0].width, closeTo(842, 1));
      expect(info.pageSizes[0].height, closeTo(595, 1));
    });

    test('rotation, duplicate and blank page', () {
      final a = makeTextPdf(['Page A']);
      final out = PdfService.rebuild([PdfSource(a)], const [PdfPageRef(0, 0, rotation: 90), PdfPageRef(0, 0), PdfPageRef(0, -1)]);
      final doc = sf.PdfDocument(inputBytes: out);
      expect(doc.pages.count, 3);
      expect(doc.pages[0].rotation, sf.PdfPageRotateAngle.rotateAngle90);
      expect(doc.pages[1].rotation, sf.PdfPageRotateAngle.rotateAngle0);
      doc.dispose();
    });

    test('password protection with AES-256 and removal', () {
      final a = makeTextPdf(['Secret text']);
      final locked = PdfService.rebuild([PdfSource(a)], const [PdfPageRef(0, 0)], newPassword: 'pass1234');
      expect(PdfService.isEncrypted(locked), isTrue);
      expect(() => PdfService.inspect(PdfSource(locked)), throwsA(isA<PdfPasswordRequired>()));
      expect(pageText(locked, 0, password: 'pass1234'), contains('Secret text'));
      final unlocked = PdfService.rebuild([PdfSource(locked, password: 'pass1234')], const [PdfPageRef(0, 0)]);
      expect(PdfService.isEncrypted(unlocked), isFalse);
      expect(pageText(unlocked, 0), contains('Secret text'));
    });

    test('split by ranges produces separate files', () {
      final a = makeTextPdf(['P1', 'P2', 'P3', 'P4']);
      final groups = PdfService.parseRanges('1-2, 4', 4);
      final files = [for (final g in groups) PdfService.rebuild([PdfSource(a)], [for (final i in g) PdfPageRef(0, i)])];
      expect(PdfService.inspect(PdfSource(files[0])).pageCount, 2);
      expect(PdfService.inspect(PdfSource(files[1])).pageCount, 1);
      expect(pageText(files[1], 0), contains('P4'));
    });

    test('text extraction from searchable PDF', () {
      final a = makeTextPdf(['Hello searchable world', 'Second']);
      final t = PdfService.extractText(PdfSource(a));
      expect(t.length, 2);
      expect(t[0], contains('searchable'));
    });

    test('damaged input is reported', () {
      expect(() => PdfService.inspect(PdfSource(Uint8List.fromList([1, 2, 3, 4]))), throwsA(anything));
    });
  });

  group('Page placement', () {
    test('fit, fill and original', () {
      const box = Rect.fromLTWH(0, 0, 100, 200);
      final fit = PdfService.placeImage(box, 400, 400, FitMode.fit);
      expect(fit.width, closeTo(100, 1e-9));
      expect(fit.top, closeTo(50, 1e-9));
      final fill = PdfService.placeImage(box, 400, 400, FitMode.fill);
      expect(fill.height, closeTo(200, 1e-9));
      final orig = PdfService.placeImage(box, 100, 100, FitMode.original, assumedDpi: 144);
      expect(orig.width, closeTo(50, 1e-9));
    });

    test('page size options', () {
      const a4 = PdfExportOptions(pageSize: PaperSizes.a4);
      final p = PdfService.pageSizeFor(a4, 1000, 1400);
      expect(p.width, closeTo(mmToPt(210), 1e-6));
      final l = PdfService.pageSizeFor(a4, 1400, 1000); // auto orientation
      expect(l.width, closeTo(mmToPt(297), 1e-6));
      const match = PdfExportOptions(pageSize: null);
      final m = PdfService.pageSizeFor(match, 1000, 2000);
      expect(m.height / m.width, closeTo(2, 1e-9));
    });
  });

  group('Print sheet export accuracy', () {
    test('A4 sheet PDF has exact physical page size', () {
      const spec = SheetSpec(paper: PaperSizes.a4, photoWmm: 35, photoHmm: 45, copies: 8);
      final layout = PrintLayoutEngine.compute(spec);
      final bytes = SheetRenderer.buildPdf(spec, layout, jpeg(827, 1063));
      final doc = sf.PdfDocument(inputBytes: bytes);
      final size = doc.pages[0].size;
      expect(ptToMm(size.width), closeTo(210, 0.05));
      expect(ptToMm(size.height), closeTo(297, 0.05));
      expect(doc.pages.count, 1);
      doc.dispose();
    });

    test('4x6 landscape sheet page size', () {
      const spec = SheetSpec(paper: PaperSizes.photo4x6, landscape: true, photoWmm: 35, photoHmm: 45, marginMm: 3);
      final layout = PrintLayoutEngine.compute(spec);
      expect(layout.placed, 8);
      final bytes = SheetRenderer.buildPdf(spec, layout, jpeg(827, 1063));
      final doc = sf.PdfDocument(inputBytes: bytes);
      final size = doc.pages[0].size;
      expect(ptToMm(size.width), closeTo(152.4, 0.05));
      expect(ptToMm(size.height), closeTo(101.6, 0.05));
      doc.dispose();
    });

    test('calibration page', () {
      final bytes = SheetRenderer.calibrationPdf(PaperSizes.a4);
      final doc = sf.PdfDocument(inputBytes: bytes);
      expect(ptToMm(doc.pages[0].size.width), closeTo(210, 0.05));
      final text = sf.PdfTextExtractor(doc).extractText();
      expect(text, contains('100 mm'));
      doc.dispose();
    });

    test('raster sheet has exact pixel size and DPI metadata', () async {
      final dir = await Directory.systemTemp.createTemp('sheet');
      final photo = File('${dir.path}/p.jpg')..writeAsBytesSync(jpeg(413, 531));
      const spec = SheetSpec(paper: PaperSizes.photo4x6, photoWmm: 35, photoHmm: 45, marginMm: 3, copies: 6);
      final layout = PrintLayoutEngine.compute(spec);
      final png = await SheetRenderer.buildRaster(spec, layout, photo.path, dpi: 300);
      final decoded = img.decodePng(png)!;
      expect(decoded.width, (101.6 / 25.4 * 300).round()); // 1200
      expect(decoded.height, (152.4 / 25.4 * 300).round()); // 1800
      expect(readPngDpi(png), 300);
      await dir.delete(recursive: true);
    });

    test('JPEG DPI patching', () {
      final j = withJpegDpi(jpeg(10, 10), 600);
      // JFIF: units at 13, X density at 14-15.
      expect(String.fromCharCodes(j.sublist(6, 10)), 'JFIF');
      expect(j[13], 1);
      expect((j[14] << 8) | j[15], 600);
      expect(img.decodeJpg(j), isNotNull);
    });

    test('PNG DPI round trip keeps the image decodable', () {
      final png = img.encodePng(img.Image(width: 4, height: 4));
      final out = withPngDpi(png, 600);
      expect(readPngDpi(out), 600);
      expect(img.decodePng(out), isNotNull);
    });
  });

  group('Scanned pages to PDF', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('scanpro_pdf');
      AppStorage.initForTest(Directory('${dir.path}/root')..createSync(), Directory('${dir.path}/cache')..createSync());
    });
    tearDown(() async => dir.delete(recursive: true));

    test('searchable PDF contains the OCR text layer; page numbers; password', () async {
      final f = File('${dir.path}/root/page.jpg')..writeAsBytesSync(jpeg(1000, 1414));
      final page = DocPage(id: 'p', docId: 'd', position: 0, originalPath: f.path, width: 1000, height: 1414, createdAt: DateTime.now());
      final ocr = OcrPageResult(
        script: 'latin',
        imageWidth: 1000,
        imageHeight: 1414,
        createdAt: DateTime.now(),
        lines: const [OcrLine(text: 'INVOICE 12345 Mumbai', left: 100, top: 100, right: 700, bottom: 160)],
      );
      final bytes = await PdfService.buildFromPages(
        [page, page],
        const PdfExportOptions(pageSize: PaperSizes.a4, searchable: true, pageNumbers: true, title: 'Test'),
        ocrFor: (_) async => ocr,
      );
      final text = PdfService.extractText(PdfSource(bytes));
      expect(text.length, 2);
      final compact = text[0].replaceAll(RegExp(r'\s'), '');
      expect(compact, contains('INVOICE'));
      expect(compact, contains('1/2'));
      final info = PdfService.inspect(PdfSource(bytes));
      expect(ptToMm(info.pageSizes[0].width), closeTo(210, 0.1));

      final locked = await PdfService.buildFromPages([page], const PdfExportOptions(password: 'abcd1234'));
      expect(PdfService.isEncrypted(locked), isTrue);
    });
  });
}
