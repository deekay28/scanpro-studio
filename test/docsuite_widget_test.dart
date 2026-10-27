import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/storage.dart';
import 'package:scanpro_studio/features/convert/conversion_service.dart';
import 'package:scanpro_studio/features/convert/ooxml/xlsx.dart';
import 'package:scanpro_studio/features/convert/ui/conversion_centre_screen.dart';
import 'package:scanpro_studio/features/convert/ui/table_review_screen.dart';
import 'package:scanpro_studio/features/docsuite/suite.dart';
import 'package:scanpro_studio/features/docsuite/ui/reader_screen.dart';
import 'package:scanpro_studio/features/docsuite/ui/reader_store.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'pdf_editor_test.dart' show findPdfium, sfDoc;

void main() {
  late Directory root;

  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    root = Directory.systemTemp.createTempSync('docsuite_ui');
    AppStorage.initForTest(Directory('${root.path}/data')..createSync(), Directory('${root.path}/cache')..createSync());
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  // Pages still rendering show spinners, so pumpAndSettle would never
  // settle; let real async work (the PDFium isolate) run between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets('Conversion Centre lists every conversion; setup shows the options of the chosen type', (tester) async {
    phone(tester);
    await tester.pumpWidget(const MaterialApp(home: ConversionCentreScreen()));
    final scroll = find.byType(Scrollable).first;
    for (final t in ConversionType.values) {
      await tester.scrollUntilVisible(find.text(t.label), 100, scrollable: scroll);
      expect(find.text(t.label), findsOneWidget, reason: t.label);
    }
    await tester.pumpWidget(const MaterialApp(home: ConversionSetupScreen(type: ConversionType.pdfToImages)));
    await tester.pump();
    for (final label in ['JPG', 'PNG', 'TIFF', 'Grayscale', 'Pack into one ZIP file', 'Choose files']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Nothing can be converted before a file is chosen.
    final convert = tester.widget<FilledButton>(find.ancestor(of: find.text('Convert'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(convert.onPressed, isNull);
    await tester.pumpWidget(const MaterialApp(home: ConversionSetupScreen(type: ConversionType.pdfToDocx)));
    await tester.pump();
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Faithful layout'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Editable document'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Editable document'), findsOneWidget);
    await tester.tap(find.text('Editable document'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('OCR for scanned pages'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('OCR for scanned pages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('table review: delete and merge columns, edit a cell, flagged cells are highlighted', (tester) async {
    phone(tester);
    final sheet = Sheet('Page 1 table 1', [
      [const SheetCell('Region', bold: true), const SheetCell('Q1', bold: true), const SheetCell('Q2', bold: true), const SheetCell('Note', bold: true)],
      [const SheetCell('North'), const SheetCell('1,200', number: 1200), const SheetCell('1O0', uncertain: true), const SheetCell('x')],
    ], headerRows: 1);
    await tester.pumpWidget(MaterialApp(home: TableReviewScreen(sheets: [sheet], warnings: const ['Check columns'], baseName: 'report')));
    await tester.pump();
    expect(find.text('2 rows × 4 columns · 1 flagged cell(s) highlighted · Tap a cell to edit; tap a column letter or row number for more.'), findsOneWidget);
    // Delete column D.
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete column'));
    await tester.pumpAndSettle();
    expect(find.text('Note'), findsNothing);
    // Merge B with C.
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge with column C'));
    await tester.pumpAndSettle();
    expect(find.text('Q1 Q2'), findsOneWidget);
    expect(find.text('1,200 1O0'), findsOneWidget);
    // Edit the merged cell.
    await tester.tap(find.text('1,200 1O0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1,300');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(find.text('1,300'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader: renders pages, remembers the page, bookmarks, switches layouts', (tester) async {
    phone(tester);
    final bytes = sfDoc((d) {
      for (var i = 0; i < 4; i++) {
        d.pages.add().graphics.drawString('Reader page ${i + 1}', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 24), bounds: const Rect.fromLTWH(60, 60, 400, 40));
      }
    });
    DocSuite.resetForTest();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(bytes: bytes, title: 'Novel', initialPage: 2)));
    for (var i = 0; i < 150 && find.text('3 / 4').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.textContaining('could not be opened'), findsNothing, reason: find.textContaining('could not').evaluate().map((e) => (e.widget as Text).data).join());
    expect(find.text('3 / 4'), findsOneWidget);
    // Wait for the visible page to render.
    for (var i = 0; i < 40 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byType(RawImage), findsWidgets);
    // Bookmark page 3.
    await tester.tap(find.byTooltip('Bookmark this page'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Chapter 2');
    await tester.tap(find.text('Add'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await settle(tester);
    expect(find.byTooltip('Remove bookmark'), findsOneWidget);
    // Book layout.
    await tester.tap(find.byTooltip('View options'));
    await settle(tester);
    await tester.tap(find.text('Book'));
    await settle(tester);
    await tester.tap(find.text('Dark (inverted)'));
    await settle(tester);
    Navigator.of(tester.element(find.text('Layout'))).pop();
    await settle(tester);
    expect(find.byType(PageView), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Close: the page and bookmark are stored.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    late ReaderStore store;
    await tester.runAsync(() async => store = await ReaderStore.get());
    final e = store.entry(ReaderStore.keyFor(bytes))!;
    expect(e.bookmarks.single.label, 'Chapter 2');
    expect(e.bookmarks.single.page, 2);
    expect(store.recent().first.title, 'Novel');
  });
}
