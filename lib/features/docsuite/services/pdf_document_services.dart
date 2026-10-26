import 'dart:typed_data';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Services built on the Syncfusion PDF library (pure Dart, already a
/// dependency): AcroForm filling and creation, hyperlinks, annotation
/// import/export and password protection with permissions. Coordinates are
/// PDF points from the page's top-left corner.

sf.PdfDocument _open(Uint8List bytes, String? password) {
  try {
    return password == null || password.isEmpty ? sf.PdfDocument(inputBytes: bytes) : sf.PdfDocument(inputBytes: bytes, password: password);
  } catch (e) {
    final m = e.toString().toLowerCase();
    if (m.contains('password')) throw const FormatException('The password is missing or incorrect.');
    throw FormatException('This PDF cannot be opened ($e).');
  }
}

Uint8List _save(sf.PdfDocument d) => Uint8List.fromList(d.saveSync());

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------

enum FormFieldKind { text, checkbox, radio, combo, list, signature, button, other }

class FormFieldInfo {
  final String name;
  final FormFieldKind kind;
  final int page;
  final Rect bounds;
  final String value; // text, selected option text, 'true'/'false'
  final List<String> options; // combo/list/radio choices
  final bool readOnly;
  const FormFieldInfo(this.name, this.kind, this.page, this.bounds, this.value, {this.options = const [], this.readOnly = false});
}

class FormSummary {
  final List<FormFieldInfo> fields;
  final bool hasXfa; // dynamic XFA forms are not supported
  const FormSummary(this.fields, this.hasXfa);
}

class PdfFormService {
  const PdfFormService();

  FormSummary read(Uint8List bytes, {String? password}) {
    final d = _open(bytes, password);
    try {
      final raw = String.fromCharCodes(bytes.length > 4000000 ? bytes.sublist(0, 4000000) : bytes);
      final hasXfa = raw.contains('/XFA');
      final out = <FormFieldInfo>[];
      final f = d.form.fields;
      for (var i = 0; i < f.count; i++) {
        final field = f[i];
        final page = field.page == null ? 0 : d.pages.indexOf(field.page!);
        final b = field.bounds;
        switch (field) {
          case sf.PdfTextBoxField t:
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.text, page, b, t.text, readOnly: field.readOnly));
          case sf.PdfCheckBoxField c:
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.checkbox, page, b, c.isChecked ? 'true' : 'false', readOnly: field.readOnly));
          case sf.PdfRadioButtonListField r:
            final opts = [for (var k = 0; k < r.items.count; k++) r.items[k].value];
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.radio, page, b, r.selectedIndex >= 0 && r.selectedIndex < opts.length ? opts[r.selectedIndex] : '',
                options: opts, readOnly: field.readOnly));
          case sf.PdfComboBoxField c:
            final opts = [for (var k = 0; k < c.items.count; k++) c.items[k].text];
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.combo, page, b, c.selectedIndex >= 0 && c.selectedIndex < opts.length ? opts[c.selectedIndex] : '',
                options: opts, readOnly: field.readOnly));
          case sf.PdfListBoxField l:
            final opts = [for (var k = 0; k < l.items.count; k++) l.items[k].text];
            final sel = l.selectedIndexes;
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.list, page, b, sel.isNotEmpty && sel.first < opts.length ? opts[sel.first] : '',
                options: opts, readOnly: field.readOnly));
          case sf.PdfSignatureField _:
            out.add(FormFieldInfo(field.name ?? 'Signature ${i + 1}', FormFieldKind.signature, page, b, ''));
          case sf.PdfButtonField _:
            out.add(FormFieldInfo(field.name ?? 'Button ${i + 1}', FormFieldKind.button, page, b, ''));
          default:
            out.add(FormFieldInfo(field.name ?? 'Field ${i + 1}', FormFieldKind.other, page, b, ''));
        }
      }
      return FormSummary(out, hasXfa);
    } finally {
      d.dispose();
    }
  }

  /// Fills fields by name. Signature images are drawn inside the signature
  /// field's area (an image of a handwritten signature, not a digital
  /// signature). With [flatten] the fields become static page content.
  Uint8List fill(Uint8List bytes, Map<String, String> values,
      {String? password, Map<String, Uint8List> signatureImages = const {}, bool flatten = false, bool keepPassword = true}) {
    final d = _open(bytes, password);
    try {
      final f = d.form.fields;
      for (var i = 0; i < f.count; i++) {
        final field = f[i];
        final name = field.name ?? '';
        final v = values[name];
        if (field is sf.PdfSignatureField) {
          final img = signatureImages[name];
          if (img != null && field.page != null) {
            final b = field.bounds;
            final bmp = sf.PdfBitmap(img);
            final k = (b.width / bmp.width) < (b.height / bmp.height) ? b.width / bmp.width : b.height / bmp.height;
            final w = bmp.width * k, h = bmp.height * k;
            field.page!.graphics.drawImage(bmp, Rect.fromLTWH(b.left + (b.width - w) / 2, b.top + (b.height - h) / 2, w, h));
          }
          continue;
        }
        if (v == null || field.readOnly) continue;
        switch (field) {
          case sf.PdfTextBoxField t:
            t.text = v;
          case sf.PdfCheckBoxField c:
            c.isChecked = v == 'true';
          case sf.PdfRadioButtonListField r:
            for (var k = 0; k < r.items.count; k++) {
              if (r.items[k].value == v) r.selectedIndex = k;
            }
          case sf.PdfComboBoxField c:
            for (var k = 0; k < c.items.count; k++) {
              if (c.items[k].text == v) c.selectedIndex = k;
            }
          case sf.PdfListBoxField l:
            for (var k = 0; k < l.items.count; k++) {
              if (l.items[k].text == v) l.selectedIndexes = [k];
            }
          default:
            break;
        }
      }
      if (flatten) d.form.flattenAllFields();
      if (!keepPassword && password != null) {
        d.security.userPassword = '';
        d.security.ownerPassword = '';
      }
      return _save(d);
    } finally {
      d.dispose();
    }
  }

  /// Adds fillable fields that stay editable in other PDF viewers.
  Uint8List create(Uint8List bytes, List<NewFormField> fields, {String? password}) {
    final d = _open(bytes, password);
    try {
      final used = <String>{for (var i = 0; i < d.form.fields.count; i++) d.form.fields[i].name ?? ''};
      for (final nf in fields) {
        if (nf.page < 0 || nf.page >= d.pages.count) throw const FormatException('Field page out of range.');
        var name = nf.name.trim().isEmpty ? 'field' : nf.name.trim();
        var k = 2;
        final base = name;
        while (used.contains(name)) {
          name = '${base}_${k++}';
        }
        used.add(name);
        final page = d.pages[nf.page];
        final sf.PdfField field = switch (nf.kind) {
          FormFieldKind.checkbox => sf.PdfCheckBoxField(page, name, nf.bounds, isChecked: nf.value == 'true', tooltip: nf.label),
          FormFieldKind.radio => sf.PdfRadioButtonListField(page, name, items: [
              for (var i = 0; i < nf.options.length; i++) sf.PdfRadioButtonListItem(nf.options[i], nf.bounds.translate(0, i * (nf.bounds.height + 6))),
            ]),
          FormFieldKind.combo => sf.PdfComboBoxField(page, name, nf.bounds,
              items: [for (final o in nf.options) sf.PdfListFieldItem(o, o)], selectedIndex: nf.options.indexOf(nf.value) < 0 ? null : nf.options.indexOf(nf.value)),
          FormFieldKind.signature => sf.PdfSignatureField(page, name, bounds: nf.bounds, tooltip: nf.label),
          _ => sf.PdfTextBoxField(page, name, nf.bounds,
              text: nf.value, tooltip: nf.label, maxLength: nf.maxLength, multiline: nf.multiline, font: sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 10)),
        };
        d.form.fields.add(field);
        if (nf.label.isNotEmpty && nf.kind != FormFieldKind.radio) {
          page.graphics.drawString(nf.label, sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 8), brush: sf.PdfBrushes.dimGray, bounds: Rect.fromLTWH(nf.bounds.left, nf.bounds.top - 11, 300, 10));
        }
      }
      return _save(d);
    } finally {
      d.dispose();
    }
  }
}

class NewFormField {
  final FormFieldKind kind;
  final String name;
  final int page;
  final Rect bounds;
  final String label;
  final String value;
  final List<String> options;
  final int maxLength; // 0 = unlimited (basic validation)
  final bool multiline;
  const NewFormField(this.kind, this.name, this.page, this.bounds, {this.label = '', this.value = '', this.options = const [], this.maxLength = 0, this.multiline = false});
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

enum LinkKind { web, email, page }

class LinkInfo {
  final int page;
  final int index; // annotation index on the page
  final Rect bounds;
  final LinkKind kind;
  final String target; // URL, address or page number (1-based)
  const LinkInfo(this.page, this.index, this.bounds, this.kind, this.target);
}

class PdfLinkService {
  const PdfLinkService();

  List<LinkInfo> list(Uint8List bytes, {String? password}) {
    final d = _open(bytes, password);
    try {
      final out = <LinkInfo>[];
      for (var p = 0; p < d.pages.count; p++) {
        final a = d.pages[p].annotations;
        for (var i = 0; i < a.count; i++) {
          final an = a[i];
          if (an is sf.PdfUriAnnotation) {
            final uri = an.uri;
            out.add(LinkInfo(p, i, an.bounds, uri.startsWith('mailto:') ? LinkKind.email : LinkKind.web, uri.startsWith('mailto:') ? uri.substring(7) : uri));
          } else if (an is sf.PdfTextWebLink) {
            out.add(LinkInfo(p, i, an.bounds, LinkKind.web, an.url));
          } else if (an is sf.PdfDocumentLinkAnnotation) {
            final dest = an.destination?.page;
            out.add(LinkInfo(p, i, an.bounds, LinkKind.page, dest == null ? '?' : '${d.pages.indexOf(dest) + 1}'));
          }
        }
      }
      return out;
    } finally {
      d.dispose();
    }
  }

  /// Adds a link. [target] is a URL, an e-mail address or a 1-based page.
  Uint8List add(Uint8List bytes, int page, Rect bounds, LinkKind kind, String target, {String? password}) {
    final d = _open(bytes, password);
    try {
      final pg = d.pages[page];
      switch (kind) {
        case LinkKind.web:
          final url = target.contains('://') ? target : 'https://$target';
          if (Uri.tryParse(url)?.host.isEmpty ?? true) throw const FormatException('Enter a valid web address.');
          pg.annotations.add(sf.PdfUriAnnotation(bounds: bounds, uri: url));
        case LinkKind.email:
          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(target)) throw const FormatException('Enter a valid e-mail address.');
          pg.annotations.add(sf.PdfUriAnnotation(bounds: bounds, uri: 'mailto:$target'));
        case LinkKind.page:
          final n = int.tryParse(target) ?? 0;
          if (n < 1 || n > d.pages.count) throw FormatException('Choose a page from 1 to ${d.pages.count}.');
          pg.annotations.add(sf.PdfDocumentLinkAnnotation(bounds, sf.PdfDestination(d.pages[n - 1])));
      }
      return _save(d);
    } finally {
      d.dispose();
    }
  }

  Uint8List remove(Uint8List bytes, LinkInfo link, {String? password}) {
    final d = _open(bytes, password);
    try {
      final a = d.pages[link.page].annotations;
      if (link.index < a.count) a.remove(a[link.index]);
      return _save(d);
    } finally {
      d.dispose();
    }
  }

  Uint8List edit(Uint8List bytes, LinkInfo link, LinkKind kind, String target, {String? password}) {
    final removed = remove(bytes, link, password: password);
    return add(removed, link.page, link.bounds, kind, target, password: password);
  }
}

// ---------------------------------------------------------------------------
// Annotations import / export
// ---------------------------------------------------------------------------

enum AnnotationFormat { xfdf, fdf, json }

class PdfAnnotationService {
  const PdfAnnotationService();

  sf.PdfAnnotationDataFormat _f(AnnotationFormat f) => switch (f) {
        AnnotationFormat.xfdf => sf.PdfAnnotationDataFormat.xfdf,
        AnnotationFormat.fdf => sf.PdfAnnotationDataFormat.fdf,
        AnnotationFormat.json => sf.PdfAnnotationDataFormat.json,
      };

  Uint8List export(Uint8List bytes, AnnotationFormat format, {String? password, String fileName = 'document.pdf'}) {
    final d = _open(bytes, password);
    try {
      return Uint8List.fromList(d.exportAnnotation(_f(format), fileName: fileName));
    } finally {
      d.dispose();
    }
  }

  Uint8List import(Uint8List bytes, Uint8List data, AnnotationFormat format, {String? password}) {
    final d = _open(bytes, password);
    try {
      d.importAnnotation(data, _f(format));
      return _save(d);
    } finally {
      d.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------

enum PdfPermission { print, copy, edit, annotate, fillForms, assemble, accessibility, highQualityPrint }

class PdfSecurityService {
  const PdfSecurityService();

  /// Encrypts with AES-256. The owner password (if given) can change the
  /// restrictions; the user password opens the file. Restrictions are
  /// honoured by compliant viewers only — they cannot stop screenshots or
  /// non-compliant software.
  Uint8List protect(Uint8List bytes, {String? currentPassword, required String userPassword, String? ownerPassword, Set<PdfPermission> allow = const {}}) {
    if (userPassword.isEmpty && (ownerPassword == null || ownerPassword.isEmpty)) throw const FormatException('Enter a password.');
    final d = _open(bytes, currentPassword);
    try {
      final s = d.security;
      s.algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit;
      s.userPassword = userPassword;
      s.ownerPassword = (ownerPassword == null || ownerPassword.isEmpty) ? userPassword : ownerPassword;
      s.permissions.clear();
      final map = {
        PdfPermission.print: sf.PdfPermissionsFlags.print,
        PdfPermission.copy: sf.PdfPermissionsFlags.copyContent,
        PdfPermission.edit: sf.PdfPermissionsFlags.editContent,
        PdfPermission.annotate: sf.PdfPermissionsFlags.editAnnotations,
        PdfPermission.fillForms: sf.PdfPermissionsFlags.fillFields,
        PdfPermission.assemble: sf.PdfPermissionsFlags.assembleDocument,
        PdfPermission.accessibility: sf.PdfPermissionsFlags.accessibilityCopyContent,
        PdfPermission.highQualityPrint: sf.PdfPermissionsFlags.fullQualityPrint,
      };
      s.permissions.addAll([for (final p in allow) map[p]!]);
      return _save(d);
    } finally {
      d.dispose();
    }
  }
}
