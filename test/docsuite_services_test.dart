import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanpro_studio/features/docsuite/services/pdf_comparison_service.dart';
import 'package:scanpro_studio/features/docsuite/services/pdf_document_services.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdf_edit_engine.dart';
import 'package:scanpro_studio/features/pdf_editor/engine/pdfium_engine.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'pdf_editor_test.dart' show findPdfium, freeSans, sfDoc, viewerText;

late PdfiumEngine engine;
PdfiumSession op(Uint8List b, {String? password}) => engine.open(b, password: password) as PdfiumSession;

Uint8List formPdf() => sfDoc((d) {
      final page = d.pages.add();
      page.graphics.drawString('Application form', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 14), bounds: const Rect.fromLTWH(40, 30, 300, 20));
      d.form.fields.add(sf.PdfTextBoxField(page, 'name', const Rect.fromLTWH(40, 80, 200, 20)));
      d.form.fields.add(sf.PdfCheckBoxField(page, 'agree', const Rect.fromLTWH(40, 120, 14, 14)));
      d.form.fields.add(sf.PdfComboBoxField(page, 'city', const Rect.fromLTWH(40, 160, 150, 20), items: [sf.PdfListFieldItem('Pune', 'pune'), sf.PdfListFieldItem('Delhi', 'delhi')]));
      d.form.fields.add(sf.PdfRadioButtonListField(page, 'gender', items: [
        sf.PdfRadioButtonListItem('F', const Rect.fromLTWH(40, 200, 14, 14)),
        sf.PdfRadioButtonListItem('M', const Rect.fromLTWH(80, 200, 14, 14)),
      ]));
      d.form.fields.add(sf.PdfSignatureField(page, 'sign', bounds: const Rect.fromLTWH(300, 300, 160, 60)));
      final b = d.bookmarks.add('Form');
      b.destination = sf.PdfDestination(page);
      page.annotations.add(sf.PdfUriAnnotation(bounds: const Rect.fromLTWH(40, 500, 100, 14), uri: 'https://gov.example'));
    });

Uint8List textPdf(List<String> pages) => sfDoc((d) {
      for (final t in pages) {
        sf.PdfTextElement(text: t, font: sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 11)).draw(page: d.pages.add(), bounds: const Rect.fromLTWH(40, 40, 480, 600));
      }
    });

void main() {
  setUpAll(() {
    PdfiumModuleSetup.init();
    engine = PdfiumEngine(unicodeFont: freeSans);
  });

  test('ACCEPTANCE 10: AcroForm read, fill (incl. signature image), flatten; links and bookmarks preserved', () {
    const svc = PdfFormService();
    final src = formPdf();
    final f = svc.read(src);
    expect(f.hasXfa, isFalse);
    expect(f.fields.map((e) => (e.name, e.kind)), containsAll([('name', FormFieldKind.text), ('agree', FormFieldKind.checkbox), ('city', FormFieldKind.combo), ('gender', FormFieldKind.radio), ('sign', FormFieldKind.signature)]));
    expect(f.fields.firstWhere((e) => e.name == 'city').options, ['Pune', 'Delhi']);
    final sig = img.Image(width: 200, height: 80, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
    img.drawLine(sig, x1: 10, y1: 60, x2: 190, y2: 20, color: img.ColorRgba8(10, 20, 120, 255), thickness: 4);
    final filled = svc.fill(src, {'name': 'Asha Rao', 'agree': 'true', 'city': 'Delhi', 'gender': 'F'}, signatureImages: {'sign': Uint8List.fromList(img.encodePng(sig))});
    final back = svc.read(filled);
    String v(String n) => back.fields.firstWhere((e) => e.name == n).value;
    expect([v('name'), v('agree'), v('city'), v('gender')], ['Asha Rao', 'true', 'Delhi', 'F']);
    // Still a form; link and bookmark preserved; the page renders the value.
    final s = op(filled);
    expect(s.annotations().where((a) => a.subtype.startsWith('Widget')).length, greaterThanOrEqualTo(5));
    expect(s.annotations().where((a) => a.subtype == 'Link').length, 1);
    expect(s.outline().single.title, 'Form');
    s.close();
    final flat = svc.fill(src, {'name': 'Asha Rao'}, flatten: true);
    expect(svc.read(flat).fields, isEmpty);
    expect(viewerText(flat), contains('Asha Rao'), reason: 'flattened value is page text');
  });

  test('create fillable fields (text, checkbox, radio, dropdown, signature) that remain editable', () {
    const svc = PdfFormService();
    final src = textPdf(['Blank form page']);
    final out = svc.create(src, const [
      NewFormField(FormFieldKind.text, 'full name', 0, Rect.fromLTWH(40, 100, 200, 20), label: 'Full name', maxLength: 40),
      NewFormField(FormFieldKind.checkbox, 'consent', 0, Rect.fromLTWH(40, 140, 14, 14), label: 'I agree'),
      NewFormField(FormFieldKind.radio, 'size', 0, Rect.fromLTWH(40, 180, 14, 14), options: ['S', 'M', 'L']),
      NewFormField(FormFieldKind.combo, 'state', 0, Rect.fromLTWH(40, 260, 120, 20), options: ['KA', 'MH'], value: 'MH'),
      NewFormField(FormFieldKind.signature, 'signature', 0, Rect.fromLTWH(300, 400, 150, 50)),
      NewFormField(FormFieldKind.text, 'full name', 0, Rect.fromLTWH(40, 300, 200, 20)),
    ]);
    final f = svc.read(out).fields;
    expect(f.map((e) => e.name), containsAll(['full name', 'consent', 'size', 'state', 'signature', 'full name_2']));
    expect(f.firstWhere((e) => e.name == 'state').value, 'MH');
    final refill = svc.fill(out, {'full name': 'Ravi', 'size': 'L'});
    final r = svc.read(refill).fields;
    expect(r.firstWhere((e) => e.name == 'full name').value, 'Ravi');
    expect(r.firstWhere((e) => e.name == 'size').value, 'L');
    expect(viewerText(out), contains('Full name'), reason: 'label drawn');
  });

  test('links: add web, e-mail and page links; list, edit, remove', () {
    const svc = PdfLinkService();
    var pdf = textPdf(['One', 'Two', 'Three']);
    pdf = svc.add(pdf, 0, const Rect.fromLTWH(40, 40, 100, 14), LinkKind.web, 'example.org/help');
    pdf = svc.add(pdf, 0, const Rect.fromLTWH(40, 60, 100, 14), LinkKind.email, 'office@example.org');
    pdf = svc.add(pdf, 0, const Rect.fromLTWH(40, 80, 100, 14), LinkKind.page, '3');
    expect(() => svc.add(pdf, 0, Rect.zero, LinkKind.page, '9'), throwsFormatException);
    var links = svc.list(pdf);
    expect(links.map((l) => (l.kind, l.target)), [(LinkKind.web, 'https://example.org/help'), (LinkKind.email, 'office@example.org'), (LinkKind.page, '3')]);
    pdf = svc.edit(pdf, links[0], LinkKind.web, 'https://example.org/new');
    links = svc.list(pdf);
    expect(links.any((l) => l.target == 'https://example.org/new'), isTrue);
    pdf = svc.remove(pdf, links.firstWhere((l) => l.kind == LinkKind.email));
    expect(svc.list(pdf).length, 2);
    final s = op(pdf);
    expect(s.annotations().where((a) => a.subtype == 'Link').length, 2);
    s.close();
  });

  test('annotations export to XFDF/JSON and import into another copy', () {
    const svc = PdfAnnotationService();
    final src = sfDoc((d) {
      final p = d.pages.add();
      p.annotations.add(sf.PdfPopupAnnotation(const Rect.fromLTWH(50, 50, 20, 20), 'Please check', author: 'QA'));
      p.annotations.add(sf.PdfRectangleAnnotation(const Rect.fromLTWH(100, 100, 80, 40), 'Box', color: sf.PdfColor(255, 0, 0)));
    });
    for (final f in AnnotationFormat.values) {
      final data = svc.export(src, f);
      expect(data, isNotEmpty);
      final target = sfDoc((d) => d.pages.add());
      final merged = svc.import(target, data, f);
      final s = op(merged);
      final a = s.annotations();
      expect(a.map((e) => e.subtype), containsAll(['Text note', 'Square']), reason: f.name);
      expect(a.firstWhere((e) => e.subtype == 'Text note').contents, 'Please check');
      s.close();
    }
  });

  test('ACCEPTANCE 9: protect with permissions; restrictions are enforced by the editor', () {
    const svc = PdfSecurityService();
    final src = textPdf(['Confidential plan']);
    final out = svc.protect(src, userPassword: 'open', ownerPassword: 'owner', allow: {PdfPermission.print});
    expect(() => op(out), throwsA(isA<EditorPasswordRequired>()));
    expect(() => op(out, password: 'open'), throwsA(isA<EditorPermissionDenied>()), reason: 'user password without edit permission');
    final s = op(out, password: 'owner');
    expect(s.pageText(0), contains('Confidential plan'));
    s.close();
    final editable = svc.protect(src, userPassword: 'open', ownerPassword: 'owner', allow: {PdfPermission.print, PdfPermission.edit});
    op(editable, password: 'open').close();
  });

  test('ACCEPTANCE 11: comparison finds inserted, deleted and changed text and page changes', () {
    final a = textPdf([
      'The contract value is 45,000 rupees payable within thirty days of delivery. The supplier will provide support for one year.',
      'Appendix A lists the equipment.'
    ]);
    final b = textPdf([
      'The contract value is 48,500 rupees payable within forty-five days of delivery. The supplier will provide free support for one year.',
      'Appendix A lists the equipment.',
      'Appendix B lists the spare parts.'
    ]);
    final sa = op(a), sb = op(b);
    final r = compareText([for (var i = 0; i < sa.pageCount; i++) sa.content(i, images: false)], [for (var i = 0; i < sb.pageCount; i++) sb.content(i, images: false)]);
    sa.close();
    sb.close();
    expect(r.structure, contains('Page count: 2 → 3.'));
    final value = r.changes.firstWhere((c) => c.oldText == '45,000');
    expect(value.newText, '48,500');
    expect(value.numeric, isTrue);
    expect(value.oldRects, isNotEmpty);
    expect(r.changes.any((c) => c.kind == ChangeKind.changed && c.oldText == 'thirty' && c.newText == 'forty-five'), isTrue);
    expect(r.changes.any((c) => c.kind == ChangeKind.inserted && c.newText == 'free'), isTrue);
    expect(r.changes.any((c) => c.kind == ChangeKind.inserted && c.newText.contains('Appendix B') && c.newPage == 2), isTrue);
    expect(r.changes.length, 4);
    // Identical documents with different rendering produce no text changes.
    final same = compareText([op(a).content(0, images: false)], [op(a).content(0, images: false)]);
    expect(same.identical, isTrue);
    // Visual comparison of image-only pages.
    final w = 100, h = 100;
    final p1 = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    final p2 = Uint8List.fromList(p1);
    for (var y = 20; y < 40; y++) {
      for (var x = 30; x < 60; x++) {
        final i = (y * w + x) * 4;
        p2[i] = p2[i + 1] = p2[i + 2] = 0;
      }
    }
    final vc = compareRender(0, p1, p2, w, h)!;
    expect(vc.regions.single.overlaps(const Rect.fromLTWH(30, 20, 30, 20)), isTrue);
    expect(compareRender(0, p1, p1, w, h), isNull);
  });
}

class PdfiumModuleSetup {
  static void init() => PdfiumEngine.modulePath = findPdfium();
}
