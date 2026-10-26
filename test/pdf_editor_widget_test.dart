import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/storage.dart';
import 'package:scanpro_studio/features/pdf_editor/editor/editor_controller.dart';
import 'package:scanpro_studio/features/pdf_editor/editor/editor_draft.dart';
import 'package:scanpro_studio/features/pdf_editor/editor/pdf_editor_screen.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/engine_worker.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdf_edit_engine.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:scanpro_studio/features/pdf_editor/model/edit_state.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc;

void main() {
  late Directory root;

  setUpAll(() {
    PdfiumEngine.modulePath = findPdfium();
    root = Directory.systemTemp.createTempSync('editor_ui');
    AppStorage.initForTest(Directory('${root.path}/data')..createSync(), Directory('${root.path}/cache')..createSync());
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  testWidgets('editor workspace: renders, selects text, adds items, undo/redo, autosaves a draft', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    final bytes = sfDoc((d) {
      for (var i = 0; i < 2; i++) {
        d.pages.add().graphics.drawString('Hello editor page ${i + 1}', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 18), bounds: const Rect.fromLTWH(60, 60, 400, 30));
      }
    });
    late PdfEditorController c;
    late EditorDraft draft;
    await tester.runAsync(() async {
      draft = await EditorDraft.create(bytes, title: 'Test doc', docId: null, encrypted: false);
      final client = await EditorEngineClient.open(bytes, freeSans);
      c = PdfEditorController(engine: client, draft: draft, title: 'Test doc', docId: null, password: null, initial: EditState.initial(client.pageCount));
    });
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: PdfEditorScreen(controller: c))));
    // Let the worker render the first page.
    for (var i = 0; i < 40 && c.image == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(c.image, isNotNull, reason: c.renderError);
    expect(tester.takeException(), isNull);
    // The tool bar scrolls horizontally on phones.
    final toolScroll = find.descendant(of: find.byKey(const ValueKey('editor-toolbar')), matching: find.byType(Scrollable));
    for (final label in ['Edit Text', 'Add Text', 'Edit Image', 'Insert Image', 'Sign', 'Annotate', 'Stamp', 'OCR', 'Pages', 'Save & Export']) {
      await tester.scrollUntilVisible(find.text(label), 80, scrollable: toolScroll);
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.scrollUntilVisible(find.text('Edit Text'), -80, scrollable: toolScroll);
    expect(find.text('Page 1 of 2'), findsOneWidget);
    expect(c.analysis!.blocks.single.text, 'Hello editor page 1');

    // Select the text block by tapping it on the canvas.
    final canvas = find.byKey(const ValueKey('editor-page'));
    final box = tester.getRect(canvas);
    final pageSize = c.slotSize!;
    final k = box.width / pageSize.width;
    final b = c.analysis!.blocks.single.bounds;
    await tester.tapAt(box.topLeft + b.center * k);
    await tester.pump();
    expect(c.selection?.blockKey, c.analysis!.blocks.single.key);
    expect(find.text('Edit text'), findsOneWidget);

    // Edit through the model (the sheet is covered by the engine tests) and
    // check undo/redo and the unsaved indicator.
    c.apply(c.state.withTextEdit(TextBlockEdit(page: 0, objects: c.analysis!.blocks.single.objects, text: 'Hello edited page 1')));
    await tester.pump();
    expect(find.textContaining('Unsaved changes'), findsOneWidget);
    c.addItem(EditItem(id: 'n1', slot: c.slot.id, kind: ItemKind.stamp, box: const Rect.fromLTWH(200, 300, 140, 50), text: 'APPROVED', color: 0xFF2E7D32));
    await tester.pump();
    expect(find.text('Duplicate'), findsOneWidget);
    c.undo();
    expect(c.state.items, isEmpty);
    c.redo();
    expect(c.state.items.length, 1);

    // Switch tools and pages without errors.
    await tester.scrollUntilVisible(find.text('Annotate'), 80, scrollable: toolScroll);
    await tester.ensureVisible(find.text('Annotate'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Annotate'));
    await tester.pump();
    expect(c.tool, EditorTool.annotate);
    expect(find.text('Select'), findsWidgets);
    expect(find.text('Highlight'), findsWidgets);
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The draft is autosaved and can be restored.
    await tester.runAsync(() async {
      await c.flushDraft();
      final restored = await draft.loadState();
      expect(restored!.items.single.text, 'APPROVED');
      expect(restored.textEdits.values.single.text, 'Hello edited page 1');
    });

    // Export through the worker and validate.
    await tester.runAsync(() async {
      final r = await c.export(const ExportOptions());
      expect(r.pageCount, 2);
      final texts = await c.engine.pageTexts(r.bytes, null);
      expect(texts.first, contains('Hello edited page 1'));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });
}
