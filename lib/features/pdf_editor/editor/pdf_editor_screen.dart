import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ids.dart';
import '../../../core/import_service.dart';
import '../../../core/naming.dart';
import '../../../core/providers.dart';
import '../../../core/storage.dart';
import '../../../shared/widgets.dart';
import '../../library/document_screen.dart';
import '../../pdf/export_actions.dart';
import '../../pdf/pdf_library.dart';
import '../engine/pdf_edit_engine.dart';
import '../model/edit_state.dart';
import 'editor_canvas.dart';
import 'editor_controller.dart';
import 'image_crop_screen.dart';
import 'image_library.dart';
import 'ocr_sheet.dart';
import 'pages_screen.dart';
import 'signature_screen.dart';
import 'text_edit_sheet.dart';

/// The PDF editing workspace.
class PdfEditorScreen extends ConsumerStatefulWidget {
  final PdfEditorController controller;
  const PdfEditorScreen({super.key, required this.controller});

  @override
  ConsumerState<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends ConsumerState<PdfEditorScreen> {
  PdfEditorController get c => widget.controller;
  Offset? _lastTap;

  @override
  void initState() {
    super.initState();
    c.start();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Size get _page => c.slotSize ?? const Size(595, 842);

  // ---------------------------------------------------------------- exit
  Future<void> _exit() async {
    if (!c.dirty) {
      await c.flushDraft();
      if (c.state.isPristine) await c.draft.delete();
      if (mounted) Navigator.pop(context);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('Your edits are kept as a draft on this device, so you can continue later. Or discard them now. The original file is unchanged either way.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard edits')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep draft')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'discard') {
      final sure = await confirm(context, 'Discard all edits?', 'This cannot be undone.', ok: 'Discard', destructive: true);
      if (!sure) return;
      await c.flushDraft();
      await c.draft.delete();
    } else {
      await c.flushDraft();
    }
    if (mounted) Navigator.pop(context);
  }

  // ---------------------------------------------------------------- text
  Future<void> _editBlock(TextBlockInfo b) async {
    final e = c.state.textEdits[b.key];
    final style = e?.style ?? b.originalStyle;
    final r = await showTextEditSheet(
      context,
      initialText: e?.text ?? b.text,
      initialStyle: style,
      block: b,
      initialShrink: e?.shrinkToFit ?? false,
      preview: (text, st, shrink) => c.previewTextEdit(TextBlockEdit(page: b.page, objects: b.objects, text: text, style: st == b.originalStyle ? null : st, box: e?.box, shrinkToFit: shrink)),
    );
    if (r == null || !mounted) return;
    final keepStyle = !r.styleChanged && e?.style == null;
    if (r.text == b.text && keepStyle && e?.box == null && !r.shrinkToFit) {
      if (e != null) c.revertBlock(b);
      return;
    }
    final edit = TextBlockEdit(page: b.page, objects: b.objects, text: r.text, style: keepStyle || r.style == b.originalStyle ? null : r.style, box: e?.box, shrinkToFit: r.shrinkToFit);
    c.apply(c.state.withTextEdit(edit));
    c.select(Selection.block(b.key));
    try {
      final rep = await c.previewTextEdit(edit);
      if (!mounted) return;
      final notes = [if (!rep.originalFontUsed) 'Font substituted: ${rep.fontUsed}.', ...rep.warnings];
      if (notes.isNotEmpty) {
        showSnack(context, 'Applied with ${notes.length} note(s) — please review.',
            action: SnackBarAction(label: 'Details', onPressed: () => _info('Review this edit', notes.join('\n\n'))));
      }
    } catch (_) {}
  }

  Future<void> _editTextItem(EditItem it) async {
    if (it.kind == ItemKind.note) {
      final t = await promptText(context, 'Note', initial: it.text, ok: 'Save');
      if (t != null) c.apply(c.state.withItem(it.copyWith(text: t)));
      return;
    }
    final r = await showTextEditSheet(context, initialText: it.text, initialStyle: it.style, title: 'Edit added text');
    if (r == null) return;
    c.apply(c.state.withItem(it.copyWith(text: r.text, style: r.style, box: _textBox(it.box.topLeft, r.text, r.style, width: it.box.width))));
  }

  Rect _textBox(Offset at, String text, TextStyleSpec s, {double? width}) {
    final w = width ?? math.max(60.0, math.min(320.0, _page.width - at.dx - 12));
    final tp = TextPainter(text: TextSpan(text: text, style: TextStyle(fontSize: s.size, height: s.lineSpacing)), textDirection: TextDirection.ltr)..layout(maxWidth: w);
    return Rect.fromLTWH(at.dx, at.dy, w, math.max(tp.height, s.size * s.lineSpacing));
  }

  Future<void> _placeText(Offset at, {String prefill = ''}) async {
    _lastTap = at;
    final r = await showTextEditSheet(context, initialText: prefill, initialStyle: const TextStyleSpec(size: 11), title: 'Add text');
    if (r == null || r.text.trim().isEmpty || !mounted) return;
    c.addItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.text, box: _textBox(at, r.text, r.style), text: r.text, style: r.style));
  }

  Future<void> _placeNote(Offset at) async {
    final t = await promptText(context, 'Add note', hint: 'Comment', ok: 'Add');
    if (t == null || t.trim().isEmpty) return;
    c.addItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.note, box: Rect.fromLTWH(at.dx, at.dy, 20, 20), text: t.trim(), color: c.annotColor));
  }

  Offset get _defaultSpot => _lastTap ?? Offset(_page.width * 0.12, _page.height * 0.12);

  void _quickText(String kind) {
    final now = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final prefill = switch (kind) {
      'date' => '${two(now.day)} ${months[now.month - 1]} ${now.year}',
      'date2' => '${two(now.day)}/${two(now.month)}/${now.year}',
      'subject' => 'Subject: ',
      'ref' => 'Ref. No.: ',
      'remarks' => 'Remarks: ',
      'name' => 'Name: ',
      'address' => 'Address: ',
      _ => '',
    };
    _placeText(_defaultSpot, prefill: prefill);
  }

  // ---------------------------------------------------------------- images
  Future<Uint8List?> _pickImageBytes() async {
    final src = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Gallery'), onTap: () => Navigator.pop(ctx, 'gallery')),
          ListTile(leading: const Icon(Icons.folder_open), title: const Text('Files'), onTap: () => Navigator.pop(ctx, 'files')),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Camera'), onTap: () => Navigator.pop(ctx, 'camera')),
          ListTile(
            leading: const Icon(Icons.collections_bookmark_outlined),
            title: const Text('Saved in ScanPro'),
            subtitle: const Text('Passport photos, seals, logos, scanned pages'),
            onTap: () => Navigator.pop(ctx, 'app'),
          ),
        ]),
      ),
    );
    if (src == null || !mounted) return null;
    switch (src) {
      case 'gallery':
        final p = await ImportService.pickImages(multiple: false);
        return p.isEmpty ? null : File(p.first).readAsBytes();
      case 'files':
        final p = await ImportService.pickImageFiles();
        return p.isEmpty ? null : File(p.first).readAsBytes();
      case 'camera':
        final p = await ImportService.captureWithSystemCamera();
        return p == null ? null : File(p).readAsBytes();
      default:
        final f = await Navigator.of(context).push<File>(MaterialPageRoute(builder: (_) => const _AppImagesScreen()));
        return f?.readAsBytes();
    }
  }

  /// Normalises an image for embedding: very large photos are reduced to
  /// 3000 px on the long side (about 300 dpi on A4), HEIC etc. become JPEG.
  Future<(Uint8List, String, double)?> _prepare(Uint8List bytes) async {
    final jpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    final png = bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final size = imageSizeOf(bytes);
    if ((jpeg || png) && size != null && math.max(size.$1, size.$2) <= 3000) {
      return (bytes, jpeg ? 'jpg' : 'png', size.$1 / size.$2);
    }
    final tmp = File('${c.draft.dir}/import_${newId()}');
    await tmp.writeAsBytes(bytes);
    try {
      final n = await ImportService.normalize(tmp.path);
      final out = await File(n.path).readAsBytes();
      final s = imageSizeOf(out);
      if (s == null) return null;
      return (out, 'jpg', s.$1 / s.$2);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> _insertImage({ImageRole role = ImageRole.picture}) async {
    final raw = await _pickImageBytes();
    if (raw == null || !mounted) return;
    final prepared = await runBusy(context, 'Preparing image…', (_) => _prepare(raw));
    if (prepared == null || !mounted) return;
    var (bytes, ext, aspect) = prepared;
    final crop = await confirm(context, 'Crop the image?', 'You can crop now or insert the whole image. You can also crop later.', ok: 'Crop');
    if (crop && mounted) {
      final r = await Navigator.of(context).push<Rect>(MaterialPageRoute(builder: (_) => ImageCropScreen(bytes: bytes, aspect: aspect)));
      if (r != null) {
        final out = await cropImageBytes(bytes, r);
        bytes = out.$1;
        ext = out.$2;
        aspect = aspect * r.width / r.height;
      }
    }
    final asset = await c.draft.addAsset(bytes, ext);
    final w = math.min(_page.width * 0.45, 260.0);
    final at = _defaultSpot;
    c.addItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.image, role: role, asset: asset, box: Rect.fromLTWH(at.dx, at.dy, w, w / aspect)));
  }

  Future<void> _replaceImage() async {
    final raw = await _pickImageBytes();
    if (raw == null || !mounted) return;
    final prepared = await _prepare(raw);
    if (prepared == null || !mounted) return;
    final asset = await c.draft.addAsset(prepared.$1, prepared.$2);
    final it = c.selectedItem;
    if (it != null) {
      c.apply(c.state.withItem(it.copyWith(asset: asset, box: Rect.fromLTWH(it.box.left, it.box.top, it.box.width, it.box.width / prepared.$3))));
      return;
    }
    final i = c.selectedImage;
    if (i != null) {
      final e = c.state.imageEdits[i.key] ?? ImageObjEdit(page: i.page, object: i.object);
      final box = c.imageBox(i);
      c.apply(c.state.withImageEdit(e.copyWith(replacement: asset, box: Rect.fromLTWH(box.left, box.top, box.width, box.width / prepared.$3))));
    }
  }

  Future<void> _cropItem() async {
    final it = c.selectedItem;
    if (it == null || it.asset == null) return;
    final bytes = await File('${c.draft.dir}/${it.asset}').readAsBytes();
    if (!mounted) return;
    final r = await Navigator.of(context).push<Rect>(MaterialPageRoute(builder: (_) => ImageCropScreen(bytes: bytes, aspect: it.box.width / it.box.height)));
    if (r == null) return;
    final out = await cropImageBytes(bytes, r);
    final asset = await c.draft.addAsset(out.$1, out.$2);
    final box = it.box;
    c.apply(c.state.withItem(it.copyWith(asset: asset, box: Rect.fromLTWH(box.left + box.width * r.left, box.top + box.height * r.top, box.width * r.width, box.height * r.height))));
  }

  Future<void> _sign() async {
    final choice = await Navigator.of(context).push<SignatureChoice>(MaterialPageRoute(builder: (_) => const SignatureScreen()));
    if (choice == null || !mounted) return;
    final asset = await c.draft.addAsset(choice.png, 'png');
    final size = imageSizeOf(choice.png) ?? (300, 120);
    final w = math.min(150.0, _page.width * 0.3);
    final h = w * size.$2 / size.$1;
    final at = _lastTap ?? Offset(_page.width - w - 48, _page.height - h - 110);
    var st = c.state.withItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.image, role: ImageRole.signature, asset: asset, box: Rect.fromLTWH(at.dx, at.dy, w, h)));
    var y = at.dy + h + 2;
    final lines = [
      if (choice.name.isNotEmpty) choice.name,
      if (choice.designation.isNotEmpty) choice.designation,
      if (choice.addDate) 'Date: ${formatDate(DateTime.now())}',
    ];
    for (final l in lines) {
      const style = TextStyleSpec(size: 9);
      st = st.withItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.text, box: Rect.fromLTWH(at.dx, y, math.max(w, 160), 12), text: l, style: style));
      y += 12;
    }
    c.apply(st);
    c.setTool(EditorTool.editImage);
    showSnack(context, 'Signature image placed. Drag to move, use the handle to resize.');
  }

  Future<void> _stamp() async {
    final t = await showModalBottomSheet<_StampChoice>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const _StampSheet());
    if (t == null || !mounted) return;
    String? asset;
    var aspect = 2.8;
    if (t.image != null) {
      asset = await c.draft.addAsset(t.image!, 'png');
      final s = imageSizeOf(t.image!);
      if (s != null) aspect = s.$1 / s.$2;
    }
    final w = t.image != null ? 110.0 : math.max(120.0, t.text.length * 10.0 + 30);
    final at = Offset((_page.width - w) / 2, _page.height * 0.15);
    c.setTool(EditorTool.stamp);
    c.addItem(EditItem(id: c.newItemId(), slot: c.slot.id, kind: ItemKind.stamp, box: Rect.fromLTWH(at.dx, at.dy, w, w / aspect), text: t.text, color: t.color, asset: asset));
  }

  // ---------------------------------------------------------------- dialogs
  Future<void> _info(String title, String body) => showDialog<void>(
      context: context, builder: (ctx) => AlertDialog(title: Text(title), content: SingleChildScrollView(child: Text(body)), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]));

  Future<void> _rotateItem() async {
    final it = c.selectedItem;
    if (it == null) return;
    var v = it.rotation;
    final r = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Rotate'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Slider(value: v.clamp(-180, 180), min: -180, max: 180, divisions: 72, label: '${v.round()}°', onChanged: (x) => set(() => v = x)),
            Wrap(spacing: 8, children: [
              for (final d in const [-90.0, 0.0, 90.0, 180.0]) OutlinedButton(onPressed: () => set(() => v = d), child: Text('${d.round()}°')),
            ]),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, v), child: const Text('Apply'))],
        ),
      ),
    );
    if (r != null) c.apply(c.state.withItem(it.copyWith(rotation: r)));
  }

  Future<void> _opacity() async {
    final it = c.selectedItem;
    final img = c.selectedImage;
    double v = it?.opacity ?? (img == null ? 1 : (c.state.imageEdits[img.key]?.opacity ?? 1));
    final r = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Transparency'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Slider(value: v, min: 0.1, max: 1, divisions: 18, label: '${(v * 100).round()}%', onChanged: (x) => set(() => v = x)),
            if (img != null) const Text('For images already in the PDF, transparency applies when the image is replaced.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, v), child: const Text('Apply'))],
        ),
      ),
    );
    if (r == null) return;
    if (it != null) c.apply(c.state.withItem(it.copyWith(opacity: r)));
    if (img != null) c.apply(c.state.withImageEdit((c.state.imageEdits[img.key] ?? ImageObjEdit(page: img.page, object: img.object)).copyWith(opacity: r)));
  }

  Future<void> _color() async {
    final it = c.selectedItem;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Colour'), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            for (final col in const [0xFFFFEB3B, 0xFF8BC34A, 0xFF4FC3F7, 0xFFF48FB1, 0xFFC62828, 0xFF1565C0, 0xFF2E7D32, 0xFF000000, 0xFFEF6C00, 0xFF6A1B9A])
              InkWell(onTap: () => Navigator.pop(ctx, col), child: CircleAvatar(backgroundColor: Color(col), radius: 18)),
          ]),
        ),
      ]),
    );
    if (picked == null) return;
    if (it != null) {
      c.apply(c.state.withItem(it.copyWith(color: picked)));
    } else {
      c.annotColor = picked;
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- pages/save
  Future<void> _pages() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPagesScreen(c: c, onExtract: (idx) => _save(only: idx))));
    if (mounted) await c.goTo(c.pageIndex);
  }

  Future<void> _save({List<int>? only}) async {
    await c.flushDraft();
    if (!mounted) return;
    final opts = await showModalBottomSheet<(ExportOptions, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SaveSheet(c: c, only: only),
    );
    if (opts == null || !mounted) return;
    final (o, action) = opts;
    final res = await runBusy(context, 'Saving and checking the PDF…', (_) => c.export(o));
    if (res == null || !mounted) return;
    final keepPw = c.engine.encrypted && o.keepEncryption ? c.password : null;
    final title = only == null ? '${c.title} (edited)' : '${c.title} (pages)';
    final name = Naming.withExtension(title, 'pdf');
    final repo = ref.read(repositoryProvider);
    String? savedDocId;
    switch (action) {
      case 'library':
        final texts = await c.engine.pageTexts(res.bytes, keepPw);
        final doc = await PdfLibrary.saveToLibrary(repo, res.bytes, title, parentId: c.docId, password: keepPw, pageTexts: texts);
        savedDocId = doc.id;
      case 'replace':
        final doc = c.docId == null ? null : await repo.getDocument(c.docId!);
        if (doc?.pdfPath == null) break;
        final texts = await c.engine.pageTexts(res.bytes, keepPw);
        final tmp = repo.storage.file('${doc!.pdfPath}.new');
        await tmp.writeAsBytes(res.bytes, flush: true);
        await tmp.rename(repo.storage.abs(doc.pdfPath!));
        await repo.db.update('documents', {'page_count': res.pageCount, 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [doc.id]);
        await repo.indexPdfText(doc.id, texts);
        repo.changed();
        savedDocId = doc.id;
      case 'share':
        await ExportActions.shareBytes(res.bytes, name, mime: 'application/pdf');
      case 'device':
        await ExportActions.saveBytes(res.bytes, name);
    }
    if (!mounted) return;
    if (only == null && (action == 'library' || action == 'replace')) {
      c.markSaved();
      await c.draft.delete();
    }
    await _report(res, savedDocId, action);
  }

  Future<void> _report(ExportResult r, String? docId, String action) async {
    final lines = [
      'The file was written and re-opened successfully: ${r.pageCount} page(s).',
      if (r.annotationsBefore > 0) 'Existing links, form fields and annotations: ${r.annotationsAfter} of ${r.annotationsBefore} kept.',
      r.encrypted ? 'Password protection: kept.' : (c.engine.encrypted ? 'Password protection: removed (as you chose).' : 'Not password protected.'),
      if (action == 'library') 'Saved as a new document; the original is unchanged.',
      if (action == 'replace') 'The original document was replaced.',
      ...r.warnings.map((w) => '⚠ $w'),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.warnings.isEmpty ? 'Saved' : 'Saved with warnings'),
        content: SingleChildScrollView(child: Text(lines.join('\n\n'))),
        actions: [
          if (docId != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: docId)));
              },
              child: const Text('Open'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exit();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: _exit),
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title, overflow: TextOverflow.ellipsis),
              Text(c.dirty ? '● Unsaved changes (draft autosaved)' : 'No unsaved changes', style: Theme.of(context).textTheme.bodySmall),
            ]),
            actions: [
              IconButton(onPressed: c.history.canUndo ? c.undo : null, icon: const Icon(Icons.undo), tooltip: 'Undo'),
              IconButton(onPressed: c.history.canRedo ? c.redo : null, icon: const Icon(Icons.redo), tooltip: 'Redo'),
              IconButton(
                onPressed: c.toggleOriginal,
                isSelected: c.showOriginal,
                icon: const Icon(Icons.compare_outlined),
                selectedIcon: const Icon(Icons.compare),
                tooltip: c.showOriginal ? 'Show edited page' : 'Show original page',
              ),
              Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton(onPressed: () => _save(), child: const Text('Save'))),
            ],
          ),
          body: Column(children: [
            ..._banners(),
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: EditorCanvas(
                  c: c,
                  onPlaceText: (p) => _placeText(p),
                  onPlaceNote: (p) => _placeNote(p),
                  onEditBlock: _editBlock,
                  onEditItem: _editTextItem,
                ),
              ),
            ),
            _contextBar(),
            _toolBar(),
            _pageBar(),
          ]),
        ),
      ),
    );
  }

  List<Widget> _banners() {
    final a = c.analysis;
    final out = <Widget>[];
    if (c.showOriginal) {
      out.add(const MaterialBanner(content: Text('Showing the original page. Tap compare again to see your edits.'), actions: [SizedBox.shrink()]));
    } else if (a != null && a.looksScanned && (c.tool == EditorTool.editText)) {
      out.add(MaterialBanner(
        leading: const Icon(Icons.document_scanner_outlined),
        content: Text(a.hasOcrLayer
            ? 'Scanned page with a hidden OCR text layer. The visible text is part of an image and cannot be edited in place.'
            : 'Scanned page: the text is part of an image and cannot be edited in place.'),
        actions: [TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrEditScreen(c: c))), child: const Text('Use OCR'))],
      ));
    } else if (a != null && c.tool == EditorTool.editText && a.formObjects > 0 && a.blocks.isEmpty) {
      out.add(const MaterialBanner(content: Text('The text on this page is inside embedded graphics (form XObjects) and cannot be edited here. Use Add Text with a cover instead.'), actions: [SizedBox.shrink()]));
    }
    return out;
  }

  Widget _bar(List<Widget> children) => Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SizedBox(height: 48, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: children)),
      );

  Widget _act(IconData i, String label, VoidCallback? onTap) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: TextButton.icon(onPressed: onTap, icon: Icon(i, size: 20), label: Text(label)));

  Widget _contextBar() {
    final it = c.selectedItem;
    final b = c.selectedBlock;
    final img = c.selectedImage;
    if (it != null) {
      final isText = it.kind == ItemKind.text;
      final isImage = it.kind == ItemKind.image;
      return _bar([
        if (isText || it.kind == ItemKind.note) _act(Icons.edit, 'Edit', () => _editTextItem(it)),
        if (isImage) _act(Icons.find_replace, 'Replace', _replaceImage),
        if (isImage) _act(Icons.crop, 'Crop', _cropItem),
        if (isText || isImage) _act(Icons.rotate_right, 'Rotate', _rotateItem),
        if (isImage || it.kind == ItemKind.stamp || isText) _act(Icons.opacity, 'Opacity', _opacity),
        if (it.kind.isAnnotation && it.kind != ItemKind.stamp) _act(Icons.palette_outlined, 'Colour', _color),
        _act(Icons.copy, 'Duplicate', c.duplicateSelection),
        _act(Icons.delete_outline, 'Delete', c.deleteSelection),
      ]);
    }
    if (b != null) {
      final edited = c.state.textEdits.containsKey(b.key);
      return _bar([
        _act(Icons.edit, 'Edit text', () => _editBlock(b)),
        _act(Icons.info_outline, 'Font info', () => _info('Text formatting', [
              'Font: ${b.first.font.baseName}',
              b.first.font.embedded ? (b.first.font.subset ? 'Embedded as a subset: only the characters used in the document are available.' : 'Fully embedded.') : 'Not embedded (a standard or system font).',
              'Size: ${b.first.size.toStringAsFixed(2)} pt · Colour: #${(b.first.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
              'Lines: ${b.lines.length} · Line spacing: ${(b.leading / b.first.size).toStringAsFixed(2)}× · Alignment: ${b.align.name}',
              if (!b.editableInPlace) 'This text is rotated; it can be rewritten but will become upright.',
            ].join('\n'))),
        if (edited) _act(Icons.restore, 'Reset', () => c.revertBlock(b)),
        _act(Icons.delete_outline, 'Delete', c.deleteSelection),
      ]);
    }
    if (img != null) {
      final edited = c.state.imageEdits.containsKey(img.key);
      return _bar([
        _act(Icons.find_replace, 'Replace', _replaceImage),
        _act(Icons.opacity, 'Opacity', _opacity),
        if (edited) _act(Icons.restore, 'Reset', () => c.revertImage(img)),
        _act(Icons.delete_outline, 'Delete', c.deleteSelection),
        Padding(padding: const EdgeInsets.all(12), child: Text('${img.pixelWidth}×${img.pixelHeight} px', style: Theme.of(context).textTheme.bodySmall)),
      ]);
    }
    switch (c.tool) {
      case EditorTool.addText:
        return _bar([
          const Padding(padding: EdgeInsets.all(14), child: Text('Tap the page to add text, or:')),
          for (final q in const [('date', 'Date'), ('date2', 'Date dd/mm/yyyy'), ('subject', 'Subject'), ('ref', 'Ref. No.'), ('remarks', 'Remarks'), ('name', 'Name'), ('address', 'Address')])
            Padding(padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6), child: ActionChip(label: Text(q.$2), onPressed: () => _quickText(q.$1))),
        ]);
      case EditorTool.annotate:
        return _bar([
          for (final t in AnnotTool.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: ChoiceChip(label: Text(t.label), selected: c.annotTool == t, onSelected: (_) => c.setAnnotTool(t)),
            ),
          IconButton(onPressed: _color, icon: Icon(Icons.circle, color: Color(c.annotColor)), tooltip: 'Colour'),
          if (c.annotTool == AnnotTool.pen || c.annotTool == AnnotTool.rect || c.annotTool == AnnotTool.ellipse || c.annotTool == AnnotTool.line || c.annotTool == AnnotTool.arrow)
            SizedBox(
              width: 140,
              child: Slider(value: c.strokeWidth, min: 0.5, max: 8, onChanged: (v) {
                c.strokeWidth = v;
                setState(() {});
              }),
            ),
        ]);
      case EditorTool.editText:
        return _bar([
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(c.analysis == null || c.analysis!.blocks.isEmpty ? 'No editable text on this page.' : 'Tap a text block to select it, tap it again to edit.'),
          ),
        ]);
      case EditorTool.editImage:
        return _bar([
          const Padding(padding: EdgeInsets.all(14), child: Text('Tap an image to move, resize or replace it.')),
          _act(Icons.add_photo_alternate_outlined, 'Insert image', () => _insertImage()),
        ]);
      case EditorTool.stamp:
        return _bar([_act(Icons.approval_outlined, 'Add stamp', _stamp), const Padding(padding: EdgeInsets.all(14), child: Text('Tap a stamp to move or resize it.'))]);
    }
  }

  Widget _toolBar() {
    Widget tool(IconData i, String label, EditorTool? t, VoidCallback onTap) {
      final sel = t != null && c.tool == t;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 74,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: sel ? Theme.of(context).colorScheme.secondaryContainer : null, borderRadius: BorderRadius.circular(10)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, size: 22),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      );
    }

    return Material(
      elevation: 3,
      child: SizedBox(
        height: 64,
        child: ListView(key: const ValueKey('editor-toolbar'), scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), children: [
          tool(Icons.edit_note, 'Edit Text', EditorTool.editText, () => c.setTool(EditorTool.editText)),
          tool(Icons.text_fields, 'Add Text', EditorTool.addText, () => c.setTool(EditorTool.addText)),
          tool(Icons.image_outlined, 'Edit Image', EditorTool.editImage, () => c.setTool(EditorTool.editImage)),
          tool(Icons.add_photo_alternate_outlined, 'Insert Image', null, () {
            c.setTool(EditorTool.editImage);
            _insertImage();
          }),
          tool(Icons.draw_outlined, 'Sign', null, _sign),
          tool(Icons.brush_outlined, 'Annotate', EditorTool.annotate, () => c.setTool(EditorTool.annotate)),
          tool(Icons.approval_outlined, 'Stamp', EditorTool.stamp, () {
            c.setTool(EditorTool.stamp);
            _stamp();
          }),
          tool(Icons.document_scanner_outlined, 'OCR', null, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrEditScreen(c: c)))),
          tool(Icons.view_agenda_outlined, 'Pages', null, _pages),
          tool(Icons.save_outlined, 'Save & Export', null, () => _save()),
        ]),
      ),
    );
  }

  Widget _pageBar() {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 44,
        child: Row(children: [
          IconButton(onPressed: c.pageIndex > 0 ? () => c.goTo(c.pageIndex - 1) : null, icon: const Icon(Icons.chevron_left), tooltip: 'Previous page'),
          Expanded(
            child: TextButton(
              onPressed: _pages,
              child: Text('Page ${c.pageIndex + 1} of ${c.pageCount}${c.slot.isBlank ? ' (blank)' : ''}${c.slot.rotation != 0 ? ' · rotated ${c.slot.rotation}° on save' : ''}'),
            ),
          ),
          IconButton(onPressed: c.pageIndex < c.pageCount - 1 ? () => c.goTo(c.pageIndex + 1) : null, icon: const Icon(Icons.chevron_right), tooltip: 'Next page'),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SaveSheet extends StatefulWidget {
  final PdfEditorController c;
  final List<int>? only;
  const _SaveSheet({required this.c, this.only});
  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  bool _flatten = false;
  bool _keepPw = true;

  ExportOptions get _o => ExportOptions(flattenAnnotations: _flatten, keepEncryption: _keepPw, onlySlots: widget.only);

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final annots = c.state.items.where((i) => i.kind.isAnnotation).length;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.only == null ? 'Save & export' : 'Extract ${widget.only!.length} page(s)', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('A new PDF is written from the original plus your edits, then re-opened to check it.'),
          if (c.engine.encrypted)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep password protection'),
              subtitle: const Text('Uses the same password and encryption as the original'),
              value: _keepPw,
              onChanged: (v) => setState(() => _keepPw = v),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Flatten annotations'),
            subtitle: Text(_flatten
                ? 'Annotations, stamps and existing FORM FIELDS on every page become fixed page content and can no longer be edited.'
                : 'Off: highlights, notes, drawings and stamps stay editable annotations${annots > 0 ? ' ($annots added)' : ''}.'),
            value: _flatten,
            onChanged: (v) => setState(() => _flatten = v),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: () => Navigator.pop(context, (_o, 'library')), icon: const Icon(Icons.library_add_outlined), label: const Text('Save as new version in Documents')),
          if (c.docId != null && widget.only == null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await confirm(context, 'Replace the original?', 'The original PDF in Documents will be overwritten with the edited version. This cannot be undone. Saving as a new version keeps both.',
                    ok: 'Replace original', destructive: true);
                if (ok && context.mounted) Navigator.pop(context, (_o, 'replace'));
              },
              icon: const Icon(Icons.warning_amber_outlined),
              label: const Text('Replace original…'),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, (_o, 'share')), icon: const Icon(Icons.share_outlined), label: const Text('Share'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, (_o, 'device')), icon: const Icon(Icons.save_alt), label: const Text('Save to device'))),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _StampChoice {
  final String text;
  final int color;
  final Uint8List? image;
  const _StampChoice(this.text, this.color, {this.image});
}

class _StampSheet extends StatefulWidget {
  const _StampSheet();
  @override
  State<_StampSheet> createState() => _StampSheetState();
}

class _StampSheetState extends State<_StampSheet> {
  static const presets = [
    ('DRAFT', 0xFF616161),
    ('APPROVED', 0xFF2E7D32),
    ('REVIEWED', 0xFF1565C0),
    ('CONFIDENTIAL', 0xFFC62828),
    ('REJECTED', 0xFFC62828),
    ('PAID', 0xFF2E7D32),
    ('RECEIVED', 0xFF1565C0),
    ('COPY', 0xFF616161),
  ];
  bool _date = false;
  final _custom = TextEditingController();
  int _color = 0xFF1565C0;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String _label(String s) => _date ? '$s · ${formatDate(DateTime.now())}' : s;

  Future<void> _imageStamp() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('From gallery'), onTap: () => Navigator.pop(ctx, 'g')),
          ListTile(leading: const Icon(Icons.collections_bookmark_outlined), title: const Text('Saved in ScanPro'), onTap: () => Navigator.pop(ctx, 'a')),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    Uint8List? bytes;
    if (source == 'g') {
      final p = await ImportService.pickImages(multiple: false);
      if (p.isEmpty) return;
      bytes = await File(p.first).readAsBytes();
      if (!mounted) return;
      final clean = await confirm(context, 'Remove the paper background?', 'Useful for photographed seals and stamps: white paper becomes transparent.', ok: 'Remove');
      if (clean) {
        try {
          bytes = await cleanSignatureImage(bytes, threshold: 0.2);
          await ImageLibrary.images.save(bytes, label: 'seal');
        } catch (e) {
          if (mounted) showSnack(context, friendlyError(e));
        }
      }
    } else {
      final f = await Navigator.of(context).push<File>(MaterialPageRoute(builder: (_) => const _AppImagesScreen()));
      bytes = await f?.readAsBytes();
    }
    if (bytes != null && mounted) Navigator.pop(context, _StampChoice('Image stamp', 0xFF000000, image: bytes));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Stamps', style: Theme.of(context).textTheme.titleLarge),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Add today\'s date'), value: _date, onChanged: (v) => setState(() => _date = v)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in presets)
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Color(p.$2), side: BorderSide(color: Color(p.$2), width: 2)),
                onPressed: () => Navigator.pop(context, _StampChoice(_label(p.$1), p.$2)),
                child: Text(p.$1, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
          ]),
          const SizedBox(height: 16),
          TextField(controller: _custom, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Custom stamp text')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final col in const [0xFF1565C0, 0xFF2E7D32, 0xFFC62828, 0xFF616161, 0xFF6A1B9A])
              ChoiceChip(label: const Text('   '), backgroundColor: Color(col), selectedColor: Color(col), selected: _color == col, onSelected: (_) => setState(() => _color = col)),
          ]),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              final t = _custom.text.trim();
              if (t.isNotEmpty) Navigator.pop(context, _StampChoice(_label(t.toUpperCase()), _color));
            },
            child: const Text('Use custom stamp'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _imageStamp, icon: const Icon(Icons.verified_outlined), label: const Text('Image stamp (seal, logo)')),
          const SizedBox(height: 8),
          const Text('Stamps are saved as PDF stamp annotations, which stay editable in other PDF apps unless you flatten them.', style: TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Images saved inside the app (passport photos, seals, logos) and pages of
/// scanned documents.
class _AppImagesScreen extends ConsumerStatefulWidget {
  const _AppImagesScreen();
  @override
  ConsumerState<_AppImagesScreen> createState() => _AppImagesScreenState();
}

class _AppImagesScreenState extends ConsumerState<_AppImagesScreen> {
  List<File> _saved = [];
  List<(String, File)> _pages = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await ImageLibrary.images.list();
    final repo = ref.read(repositoryProvider);
    final pages = <(String, File)>[];
    for (final d in (await repo.listDocuments()).take(30)) {
      if (d.isPdf) continue;
      for (final p in (await repo.getPages(d.id)).take(4)) {
        final f = repo.storage.file(p.displayPath);
        if (await f.exists()) pages.add((d.title, f));
      }
    }
    if (mounted) {
      setState(() {
        _saved = saved;
        _pages = pages;
      });
    }
  }

  Widget _grid(List<(String, File)> items, {bool deletable = false}) => GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          for (final (label, f) in items)
            InkWell(
              onTap: () => Navigator.pop(context, f),
              onLongPress: deletable
                  ? () async {
                      if (await confirm(context, 'Delete this image?', 'It is removed from ScanPro.', ok: 'Delete', destructive: true)) {
                        await ImageLibrary.images.delete(f);
                        await _load();
                      }
                    }
                  : null,
              child: Column(children: [
                Expanded(child: Container(color: Colors.white, child: Image.file(f, fit: BoxFit.contain, cacheWidth: 300))),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              ]),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved in ScanPro')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const SectionHeader('Photos, seals and logos'),
        if (_saved.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing saved yet. In ID Photo Studio, use "Keep photo for PDF editor".')),
        _grid([for (final f in _saved) ('', f)], deletable: true),
        const SectionHeader('Scanned pages'),
        if (_pages.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No scanned documents yet.')),
        _grid(_pages),
      ]),
    );
  }
}
