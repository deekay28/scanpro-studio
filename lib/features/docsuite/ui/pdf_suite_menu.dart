import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../shared/widgets.dart';
import '../../convert/ui/conversion_centre_screen.dart';
import '../../pdf/pdf_library.dart';
import '../../pdf/pdf_service.dart';
import 'compare_screen.dart';
import 'document_tools_screens.dart';
import 'reader_screen.dart';
import 'security_tools_screens.dart';

/// Every document-suite tool for one PDF, from the viewer's "More tools"
/// button or after picking a file in Tools. Each tool writes a new copy;
/// the PDF shown in the viewer is never changed in place.
class PdfSuiteMenu {
  static const tools = <(String, IconData, String, String)>[
    ('read', Icons.chrome_reader_mode_outlined, 'Read', 'Book, two-page and night modes, bookmarks, read aloud'),
    ('convert', Icons.swap_horiz, 'Convert', 'Word, Excel, PowerPoint, images, text, HTML'),
    ('compare', Icons.compare, 'Compare with another PDF', 'Find inserted, deleted and changed text'),
    ('fill', Icons.edit_note, 'Fill form', 'Fill fields and sign signature areas'),
    ('form', Icons.add_box_outlined, 'Create fillable form', 'Text, checkbox, choice, dropdown, signature'),
    ('stamp', Icons.format_list_numbered, 'Headers, footers & watermark', 'Page numbers, dates, titles, logos'),
    ('links', Icons.link, 'Links', 'Add, edit or remove web, e-mail and page links'),
    ('annotations', Icons.sticky_note_2_outlined, 'Annotations', 'Summary, export/import XFDF/JSON, flatten'),
    ('bookmarks', Icons.bookmarks_outlined, 'Bookmarks (outline)', 'Table of contents for PDF readers'),
    ('redact', Icons.format_color_fill, 'Redact', 'Permanently remove sensitive content'),
    ('protect', Icons.lock_outline, 'Protect with password', 'AES-256 with optional permissions'),
    ('compress', Icons.compress, 'Compress', 'Size profiles that keep text, links and forms'),
    ('pages', Icons.note_add_outlined, 'Page tools', 'Lined/grid pages, replace pages, repair'),
  ];

  static Future<void> show(BuildContext context, Uint8List bytes, String title, {String? password, String? parentId}) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(controller: sc, children: [
          for (final t in tools) ListTile(leading: Icon(t.$2), title: Text(t.$3), subtitle: Text(t.$4), onTap: () => Navigator.pop(ctx, t.$1)),
        ]),
      ),
    );
    if (id == null || !context.mounted) return;
    await run(context, id, bytes, title, password: password, parentId: parentId);
  }

  static Future<void> run(BuildContext context, String id, Uint8List bytes, String title, {String? password, String? parentId}) async {
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    switch (id) {
      case 'read':
        await ReaderScreen.open(context, bytes, title, password: password);
      case 'convert':
        await ConversionCentreScreen.convertPdf(context, bytes, title, password: password);
      case 'compare':
        LoadedPdf first;
        try {
          first = LoadedPdf(bytes, title, password, PdfService.inspect(PdfSource(bytes, password: password)));
        } catch (e) {
          showSnack(context, 'This PDF cannot be compared: $e');
          return;
        }
        push(CompareScreen(first: first));
      case 'fill':
        push(FormFillScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'form':
        push(FormBuilderScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'stamp':
        push(StampScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'links':
        push(LinksScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'annotations':
        push(AnnotationsScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'bookmarks':
        push(BookmarksScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'redact':
        push(RedactScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'protect':
        await protectWithPermissions(context, bytes, title, password: password, parentId: parentId);
      case 'compress':
        push(CompressScreen(bytes: bytes, title: title, password: password, parentId: parentId));
      case 'pages':
        push(PageToolsScreen(bytes: bytes, title: title, password: password, parentId: parentId));
    }
  }

  /// Picks a PDF (asking for its password if needed), then runs tool [id].
  static Future<void> pickThen(BuildContext context, String id) async {
    if (id == 'compare') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompareScreen()));
      return;
    }
    try {
      final l = await PdfLibrary.pickAndOpen(context);
      if (l.isEmpty || !context.mounted) return;
      await run(context, id, l.first.bytes, l.first.name, password: l.first.password);
    } catch (e) {
      if (context.mounted) showSnack(context, '$e');
    }
  }
}
