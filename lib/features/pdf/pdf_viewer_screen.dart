import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/ids.dart';
import '../../core/naming.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../shared/widgets.dart';
import '../library/document_screen.dart';
import '../docsuite/ui/pdf_suite_menu.dart';
import '../pdf_editor/pdf_editor_launcher.dart';
import 'export_actions.dart';
import 'pdf_library.dart';
import 'pdf_service.dart';

/// Shows a generated or loaded PDF with save / share / print actions.
/// The preview renders the actual PDF bytes (what you see is what is saved).
class PdfViewerScreen extends ConsumerStatefulWidget {
  final Uint8List bytes;
  final String title;
  final bool offerSaveToLibrary;
  final String? parentId;
  final String? password; // when the bytes are encrypted
  final String? printWarning;
  const PdfViewerScreen({
    super.key,
    required this.bytes,
    required this.title,
    this.offerSaveToLibrary = true,
    this.parentId,
    this.password,
    this.printWarning,
  });

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  Uint8List? _viewBytes;
  String? _viewError;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _prepareView();
  }

  void _prepareView() {
    try {
      if (widget.password != null && widget.password!.isNotEmpty) {
        // The platform renderer cannot open encrypted PDFs: decrypt a copy
        // in memory for display only.
        final info = PdfService.inspect(PdfSource(widget.bytes, password: widget.password));
        _viewBytes = PdfService.rebuild(
          [PdfSource(widget.bytes, password: widget.password)],
          [for (var i = 0; i < info.pageCount; i++) PdfPageRef(0, i)],
        );
      } else if (PdfService.isEncrypted(widget.bytes)) {
        _viewError = 'This PDF is password protected. It can be saved, shared or printed, but not previewed here.';
      } else {
        _viewBytes = widget.bytes;
      }
    } catch (e) {
      _viewError = friendlyError(e);
    }
  }

  String get _fileName => Naming.withExtension(widget.title, 'pdf');

  Future<void> _saveDevice() async {
    try {
      final path = await ExportActions.saveBytes(widget.bytes, _fileName);
      if (path != null && mounted) showSnack(context, 'Saved $_fileName');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _share() async {
    try {
      await ExportActions.shareBytes(widget.bytes, _fileName, mime: 'application/pdf');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _print() async {
    if (widget.printWarning != null) {
      final ok = await confirm(context, 'Before printing', widget.printWarning!, ok: 'Open print dialog');
      if (!ok) return;
    }
    try {
      await ExportActions.printPdf(widget.bytes, widget.title);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _saveLibrary() async {
    final repo = ref.read(repositoryProvider);
    final doc = await runBusy(context, 'Saving to library…',
        (_) => PdfLibrary.saveToLibrary(repo, widget.bytes, widget.title, parentId: widget.parentId, password: widget.password));
    if (doc == null || !mounted) return;
    setState(() => _saved = true);
    showSnack(context, 'Saved to Documents',
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(docId: doc.id))),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final view = _viewBytes;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: () => PdfEditorLauncher.open(context, widget.bytes, widget.title, password: widget.password),
            icon: const Icon(Icons.edit_document),
            tooltip: 'Edit PDF',
          ),
          IconButton(onPressed: _share, icon: const Icon(Icons.share_outlined), tooltip: 'Share'),
          IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print'),
          IconButton(onPressed: _saveDevice, icon: const Icon(Icons.save_alt), tooltip: 'Save to device'),
          IconButton(
            onPressed: () => PdfSuiteMenu.show(context, widget.bytes, widget.title, password: widget.password, parentId: widget.parentId),
            icon: const Icon(Icons.more_vert),
            tooltip: 'More tools',
          ),
        ],
      ),
      body: Column(children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(_fileName, overflow: TextOverflow.ellipsis),
            subtitle: Text(formatBytes(widget.bytes.length) + (widget.password != null ? ' · password protected' : '')),
            trailing: widget.offerSaveToLibrary
                ? FilledButton.tonalIcon(
                    onPressed: _saved ? null : _saveLibrary,
                    icon: Icon(_saved ? Icons.check : Icons.library_add_outlined),
                    label: Text(_saved ? 'Saved' : 'Save in app'),
                  )
                : null,
          ),
        ),
        Expanded(
          child: view == null
              ? EmptyState(icon: Icons.lock_outline, title: 'Preview unavailable', message: _viewError)
              : PdfPreview(
                  build: (_) async => view,
                  useActions: false,
                  canChangeOrientation: false,
                  canChangePageFormat: false,
                  canDebug: false,
                  pdfFileName: _fileName,
                  loadingWidget: const CircularProgressIndicator(),
                ),
        ),
      ]),
    );
  }
}
