import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:scanpro_studio/features/convert/conversion_jobs.dart';
import 'package:scanpro_studio/features/convert/conversion_service.dart';
import 'package:scanpro_studio/features/convert/model/page_content.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'conversion_test.dart' show reportPdf;
import 'convert_support.dart';
import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc;

Uint8List textPdf(int pages, {String prefix = 'Page', String? password}) => sfDoc((d) {
      final f = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12);
      for (var i = 0; i < pages; i++) {
        d.pages.add().graphics.drawString('$prefix ${i + 1} contents', f, bounds: const Rect.fromLTWH(40, 40, 400, 20));
      }
      if (password != null) {
        d.security
          ..algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit
          ..userPassword = password
          ..ownerPassword = password;
      }
    });

/// An image-only page (a "scan").
Uint8List scanPdf() => sfDoc((d) {
      final page = d.pages.add();
      final im = img.Image(width: 400, height: 560)..clear(img.ColorRgb8(250, 250, 245));
      page.graphics.drawImage(sf.PdfBitmap(Uint8List.fromList(img.encodePng(im))), Rect.fromLTWH(0, 0, page.getClientSize().width, page.getClientSize().height));
    });

void main() {
  late Directory tmp;
  late ConversionService service;
  late ConversionJobManager jobs;
  var ocrCalls = 0;

  ConversionJobManager manager() => ConversionJobManager(
        root: p.join(tmp.path, 'jobs'),
        runner: (job, outDir, onProgress, cancel) => service.run(
          job.type,
          [for (final i in job.inputs) (i.path, i.name, job.passwords[i.name])],
          job.options,
          outDir,
          job.outputName,
          onProgress: onProgress,
          cancel: cancel,
        ),
      );

  String put(String name, Uint8List bytes) => (File(p.join(tmp.path, name))..writeAsBytesSync(bytes)).path;

  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    tmp = Directory.systemTemp.createTempSync('jobs');
    service = ConversionService(
      unicodeFont: freeSans,
      ocr: (png, w, h, script) async {
        ocrCalls++;
        // Stand-in for ML Kit (Android only): recognised words in pixels.
        return [
          PdfWord('Scanned', Rect.fromLTWH(w * 0.1, h * 0.1, w * 0.2, h * 0.03), confidence: 0.95),
          PdfWord('letter', Rect.fromLTWH(w * 0.32, h * 0.1, w * 0.15, h * 0.03), confidence: 0.9),
        ];
      },
    );
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));
  setUp(() async {
    jobs = manager();
    await jobs.load();
  });

  test('ACCEPTANCE 8: batch of PDFs → DOCX in one job; outputs validated by python-docx', () async {
    final files = [for (var i = 0; i < 3; i++) (put('doc$i.pdf', textPdf(2, prefix: 'Doc$i')), 'doc$i.pdf')];
    final job = await jobs.enqueue(ConversionType.pdfToDocx, files, const ConversionOptions(), 'batch');
    await jobs.idle();
    expect(job.status, JobStatus.done, reason: job.error);
    expect(job.outputs.map((o) => o.name), ['doc0.docx', 'doc1.docx', 'doc2.docx']);
    for (var i = 0; i < 3; i++) {
      final s = officeSummary(File(job.outputs[i].path).readAsBytesSync(), 'docx');
      expect((s['paragraphs'] as List).join(' '), contains('Doc$i 2 contents'));
    }
    // History survives a restart.
    final again = manager();
    await again.load();
    expect(again.jobs.first.status, JobStatus.done);
    expect(again.jobs.first.outputs.length, 3);
  });

  test('PDF → images: page range, PNG, ZIP packaging and file-name template', () async {
    final job = await jobs.enqueue(ConversionType.pdfToImages, [(put('ten.pdf', textPdf(10)), 'ten.pdf')],
        const ConversionOptions(pageRange: '2-3, 9', imageFormat: RasterFormat.png, dpi: 72, zip: true, fileNameTemplate: 'scan-{n}'), 'ten');
    await jobs.idle();
    expect(job.status, JobStatus.done, reason: job.error);
    final zip = ZipDecoder().decodeBytes(File(job.outputs.single.path).readAsBytesSync());
    expect(zip.files.map((f) => f.name), ['scan-02.png', 'scan-03.png', 'scan-09.png']);
    final first = img.decodePng(Uint8List.fromList(zip.files.first.content as List<int>))!;
    expect(first.width, 595);
  });

  test('ACCEPTANCE 9: password-protected input fails without the password, then retry succeeds', () async {
    final job = await jobs.enqueue(ConversionType.pdfToText, [(put('locked.pdf', textPdf(1, password: 's3cret')), 'locked.pdf')], const ConversionOptions(), 'locked',
        encrypted: {'locked.pdf'});
    await jobs.idle();
    expect(job.status, JobStatus.failed);
    expect(job.error, contains('password'));
    expect(job.canRetry, isTrue);
    await jobs.retry(job, passwords: {'locked.pdf': 's3cret'});
    await jobs.idle();
    expect(job.status, JobStatus.done, reason: job.error);
    expect(File(job.outputs.single.path).readAsStringSync(), contains('Page 1 contents'));
    expect(File(p.join(tmp.path, 'jobs', 'jobs.json')).readAsStringSync(), isNot(contains('s3cret')), reason: 'passwords are never stored');
  });

  test('scanned PDF uses OCR; without OCR the user is told text was not converted', () async {
    ocrCalls = 0;
    final job = await jobs.enqueue(ConversionType.pdfToDocx, [(put('scan.pdf', scanPdf()), 'scan.pdf')], const ConversionOptions(), 'scan');
    await jobs.idle();
    expect(job.status, JobStatus.done, reason: job.error);
    expect(ocrCalls, 1);
    expect((officeSummary(File(job.outputs.single.path).readAsBytesSync(), 'docx')['paragraphs'] as List).join(), contains('Scanned letter'));
    expect(job.warnings.join(' '), contains('OCR'));
    final noOcr = await jobs.enqueue(ConversionType.pdfToText, [(put('scan2.pdf', scanPdf()), 'scan2.pdf')], const ConversionOptions(ocr: false), 'scan2');
    await jobs.idle();
    expect(noOcr.status, JobStatus.failed, reason: 'an empty text file is not reported as success');
    expect(noOcr.error, contains('Turn on OCR'));
  });

  test('ACCEPTANCE 13 + 15: large document, cancellation, recovery after the app is killed, validation', () async {
    final big = put('big.pdf', textPdf(200));
    final sw = Stopwatch()..start();
    final job = await jobs.enqueue(ConversionType.pdfToText, [(big, 'big.pdf')], const ConversionOptions(), 'big');
    await jobs.idle();
    expect(job.status, JobStatus.done, reason: job.error);
    final text = File(job.outputs.single.path).readAsStringSync();
    expect(text, allOf(contains('Page 1 contents'), contains('Page 200 contents')));
    expect(sw.elapsed.inSeconds, lessThan(90));
    // Cancel a running job: no partial output is left behind.
    final c = await jobs.enqueue(ConversionType.pdfToImages, [(big, 'big.pdf')], const ConversionOptions(dpi: 40), 'imgs');
    while (c.status != JobStatus.running || c.progress == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    jobs.cancel(c);
    await jobs.idle();
    expect(c.status, JobStatus.cancelled);
    expect(Directory(p.join(c.dir, 'out')).existsSync(), isFalse);
    // Simulate the app being killed during a job.
    final history = File(p.join(tmp.path, 'jobs', 'jobs.json'));
    final list = jsonDecode(history.readAsStringSync()) as List;
    (list.firstWhere((j) => j['id'] == c.id) as Map)['s'] = 'running';
    history.writeAsStringSync(jsonEncode(list));
    final restarted = manager();
    await restarted.load();
    final rec = restarted.jobs.firstWhere((j) => j.id == c.id);
    expect(rec.status, JobStatus.interrupted);
    await restarted.retry(rec);
    await restarted.idle();
    expect(rec.status, JobStatus.done, reason: rec.error);
    expect(rec.outputs.length, 200);
    // Invalid outputs are rejected before success is reported.
    await expectLater(validateOutput('x.docx', Uint8List.fromList([1, 2, 3])), throwsA(anything));
    await expectLater(validateOutput('x.pdf', utf8Bytes('not a pdf')), throwsA(isA<FormatException>()));
    expect(uniqueName(c.dir, 'in'), 'in (2)', reason: 'duplicate names get a suffix');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('wrong input type is refused; Office and image conversions run through the queue', () async {
    await expectLater(jobs.enqueue(ConversionType.docxToPdf, [(put('x.pdf', textPdf(1)), 'x.pdf')], const ConversionOptions(), 'x'), throwsFormatException);
    final png = img.encodePng(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(10, 200, 10)));
    final j = await jobs.enqueue(ConversionType.imagesToPdf, [(put('a.png', Uint8List.fromList(png)), 'a.png'), (put('b.png', Uint8List.fromList(png)), 'b.png')], const ConversionOptions(), 'album');
    await jobs.idle();
    expect(j.status, JobStatus.done, reason: j.error);
    final d = sf.PdfDocument(inputBytes: File(j.outputs.single.path).readAsBytesSync());
    expect(d.pages.count, 2);
    expect(d.pages[0].size.width, closeTo(841.89, 0.5), reason: 'landscape image on a landscape A4 page');
    d.dispose();
  });

  test('table review: previewSheets gives the tables the export writes, ready for correction', () async {
    final path = put('report.pdf', reportPdf());
    final (sheets, warnings) = await service.previewSheets(ConversionType.pdfToXlsx, path, null, const ConversionOptions());
    expect(sheets.map((s) => s.name), ['Page 1 table 1', 'Page 2 table 1']);
    expect(sheets.first.rows.any((r) => r.map((c) => c.text).join('|') == 'South|950|38,250.50'), isTrue);
    expect(warnings.join(' '), contains('check merged cells'));
    final onlyP2 = await service.previewSheets(ConversionType.pdfToXlsx, path, null, const ConversionOptions(pageRange: '2'));
    expect(onlyP2.$1.map((s) => s.name), ['Page 2 table 1']);
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
