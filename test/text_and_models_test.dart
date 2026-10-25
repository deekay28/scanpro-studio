import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/models.dart';
import 'package:scanpro_studio/core/naming.dart';
import 'package:scanpro_studio/core/ocr_models.dart';
import 'package:scanpro_studio/core/search_query.dart';
import 'package:scanpro_studio/features/ocr/text_analysis.dart';
import 'package:scanpro_studio/features/passport/photo_presets.dart';
import 'package:scanpro_studio/features/pdf/pdf_service.dart';

void main() {
  group('Entity extraction', () {
    const invoice = '''ACME TRADERS PVT LTD
TAX INVOICE
GSTIN: 27ABCDE1234F1Z5
Invoice No: 1042   Date: 12/03/2024
Bill to: Ravi Kumar, +91 98765 43210
Item A   2   ₹ 1,200.00
Item B   1   Rs. 350.50
Grand Total: ₹ 1,550.50
Contact: billing@acme.example
''';

    test('dates, amounts, total, phone, email, GSTIN', () {
      final e = TextAnalysis.extract(invoice);
      expect(e.dates, contains('12/03/2024'));
      expect(e.amounts.any((a) => a.contains('1,200.00')), isTrue);
      expect(e.total, contains('1,550.50'));
      expect(e.phones.any((p) => p.replaceAll(RegExp(r'\D'), '').endsWith('9876543210')), isTrue);
      expect(e.emails, contains('billing@acme.example'));
      expect(e.gstins, contains('27ABCDE1234F1Z5'));
    });

    test('textual dates', () {
      final e = TextAnalysis.extract('Issued on 5 January 2023 and valid until March 3, 2025');
      expect(e.dates.length, 2);
    });

    test('rejects impossible dates', () {
      expect(TextAnalysis.extract('Ref 45/78/2024').dates, isEmpty);
    });

    test('classification and name suggestions', () {
      expect(TextAnalysis.classify(invoice), 'Invoice');
      expect(TextAnalysis.classify('hello world'), isNull);
      final names = TextAnalysis.suggestNames(invoice, now: DateTime(2024, 3, 15));
      expect(names.first, contains('Invoice'));
      expect(names.any((n) => n.contains('ACME TRADERS')), isTrue);
      expect(names.last, 'Scan 2024-03-15');
    });

    test('review flags', () {
      expect(TextAnalysis.needsReview('The quick brown fox'), isFalse);
      expect(TextAnalysis.needsReview('Th3 qu1ck br0wn f0x'), isTrue);
      expect(TextAnalysis.needsReview('§¶‡†¤ ¦¨ ©'), isTrue);
      expect(TextAnalysis.needsReview('नमस्ते दुनिया'), isFalse);
      expect(TextAnalysis.needsReview('Totalकुल'), isTrue);
      expect(TextAnalysis.needsReview('fine', confidence: 0.3), isTrue);
    });

    test('table extraction to CSV', () {
      OcrLine l(String t, double x, double y) => OcrLine(text: t, left: x, top: y, right: x + 50, bottom: y + 12);
      final lines = [
        l('Item', 10, 10), l('Qty', 200, 11), l('Price', 300, 10),
        l('Pen', 10, 40), l('2', 202, 41), l('20.00', 301, 40),
        l('Book, A5', 10, 70), l('1', 201, 70), l('150.00', 300, 71),
      ];
      final table = TextAnalysis.extractTable(lines);
      expect(table.length, 3);
      expect(table[0], ['Item', 'Qty', 'Price']);
      expect(table[2], ['Book, A5', '1', '150.00']);
      final csv = TextAnalysis.toCsv(table);
      expect(csv.split('\r\n')[2], '"Book, A5",1,150.00');
    });
  });

  group('Search query', () {
    test('builds safe FTS expressions', () {
      expect(buildFtsQuery(''), isNull);
      expect(buildFtsQuery('invoice'), 'invoice*');
      expect(buildFtsQuery('Ravi kumar'), 'ravi kumar*');
      expect(buildFtsQuery('"tax invoice" 2024'), '"tax invoice" 2024*');
      expect(buildFtsQuery('a OR b'), 'a b');
      expect(buildFtsQuery('foo-bar*'), 'foo bar*');
      expect(buildFtsQuery('नमस्ते'), 'नमस्ते*');
    });

    test('snippets', () {
      final s = makeSnippet('x' * 100 + 'needle' + 'y' * 100, ['needle'], radius: 10);
      expect(s, contains('needle'));
      expect(s.startsWith('…'), isTrue);
    });
  });

  group('Naming', () {
    test('sanitize', () {
      expect(Naming.sanitize('a/b:c*?"<>|d'), 'a b c d');
      expect(Naming.sanitize('   '), 'Document');
      expect(Naming.sanitize('...hidden'), 'hidden');
      expect(Naming.sanitize('x' * 200).length, 80);
    });

    test('extension and uniqueness', () {
      expect(Naming.withExtension('Report', 'pdf'), 'Report.pdf');
      expect(Naming.withExtension('Report.PDF', 'pdf'), 'Report.PDF');
      expect(Naming.unique('Scan', ['scan', 'Scan (2)']), 'Scan (3)');
      expect(Naming.unique('New', ['Old']), 'New');
    });

    test('default title', () {
      expect(Naming.defaultScanTitle(DateTime(2025, 1, 2, 3, 4)), 'Scan 2025-01-02 03.04');
    });
  });

  group('Models', () {
    test('PageEdit JSON round trip', () {
      const e = PageEdit(
        corners: [0.1, 0.2, 0.9, 0.1, 0.95, 0.9, 0.05, 0.85],
        rotation: 270,
        fineAngle: -1.5,
        preset: FilterPreset.receipt,
        brightness: 0.2,
        contrast: -0.1,
        threshold: 0.3,
        adaptiveBw: false,
        flatten: true,
      );
      final d = PageEdit.decode(e.encode());
      expect(d.corners, e.corners);
      expect(d.rotation, 270);
      expect(d.fineAngle, -1.5);
      expect(d.preset, FilterPreset.receipt);
      expect(d.adaptiveBw, isFalse);
      expect(d.flatten, isTrue);
      expect(PageEdit.decode('not json').isIdentity, isTrue);
      expect(const PageEdit().isIdentity, isTrue);
      expect(d.resetAdjustments().hasManualAdjustments, isFalse);
    });

    test('DocPage row round trip', () {
      final p = DocPage(
        id: 'p1',
        docId: 'd1',
        position: 3,
        originalPath: 'docs/d1/orig/p1.jpg',
        processedPath: 'docs/d1/proc/p1_1.jpg',
        flags: const ['blurry', 'dark'],
        width: 100,
        height: 200,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final r = DocPage.fromRow(p.toRow());
      expect(r.position, 3);
      expect(r.flags, ['blurry', 'dark']);
      expect(r.displayPath, 'docs/d1/proc/p1_1.jpg');
    });

    test('OCR result serialisation and text assembly', () {
      final r = OcrPageResult(
        script: 'devanagari',
        imageWidth: 10,
        imageHeight: 20,
        createdAt: DateTime.fromMillisecondsSinceEpoch(5),
        lines: const [
          OcrLine(text: 'नमस्ते', left: 0, top: 0, right: 1, bottom: 1, block: 0),
          OcrLine(text: 'Hello', left: 0, top: 2, right: 1, bottom: 3, block: 0, flagged: true),
          OcrLine(text: 'World', left: 0, top: 5, right: 1, bottom: 6, block: 1, confidence: 0.8),
        ],
      );
      expect(r.text, 'नमस्ते\nHello\n\nWorld');
      final d = OcrPageResult.decode(r.encode())!;
      expect(d.lines[1].flagged, isTrue);
      expect(d.lines[2].confidence, 0.8);
      expect(d.flaggedCount, 1);
    });

    test('Session item round trip', () {
      const s = SessionItem(path: 'sessions/a/b.jpg', corners: [0, 0, 1, 0, 1, 1, 0, 1], flags: ['duplicate'], spine: 0.48, rotation: 90);
      final d = SessionItem.fromJson(s.toJson());
      expect(d.spine, 0.48);
      expect(d.rotation, 90);
      expect(d.flags, ['duplicate']);
    });
  });

  group('Photo presets', () {
    test('built-ins are valid and pixel sizes follow DPI', () {
      for (final p in builtInPresets) {
        expect(p.validate(), isEmpty, reason: p.name);
      }
      final india = builtInPresets.firstWhere((p) => p.id == 'in_passport');
      expect(india.widthMm, 35);
      expect(india.heightMm, 45);
      expect(india.pixelWidth, 827);
      expect(india.pixelHeight, 1063);
      final j = PhotoPreset.fromJson(india.toJson());
      expect(j.headMax, india.headMax);
    });

    test('invalid presets are rejected', () {
      const p = PhotoPreset(id: 'x', name: '', category: 'custom', widthMm: 5, heightMm: 45, dpi: 50, headMin: 0.9, headMax: 0.5);
      expect(p.validate().length, greaterThanOrEqualTo(3));
    });
  });

  group('PDF helpers', () {
    test('page ranges', () {
      expect(PdfService.parseRanges('1-3, 5, 8-', 10), [
        [0, 1, 2],
        [4],
        [7, 8, 9],
      ]);
      expect(() => PdfService.parseRanges('0-2', 5), throwsFormatException);
      expect(() => PdfService.parseRanges('4-2', 5), throwsFormatException);
      expect(() => PdfService.parseRanges('abc', 5), throwsFormatException);
      expect(() => PdfService.parseRanges('', 5), throwsFormatException);
    });
  });
}
