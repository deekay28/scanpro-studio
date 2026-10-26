import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/ids.dart';
import '../../core/storage.dart';
import '../../shared/widgets.dart';
import '../pdf/pdf_library.dart';
import 'editor/editor_controller.dart';
import 'editor/editor_draft.dart';
import 'editor/pdf_editor_screen.dart';
import 'engine/engine_worker.dart';
import 'engine/pdf_edit_engine.dart';
import 'model/edit_state.dart';

/// Entry points into the PDF editor from the library, the PDF viewer, the
/// tools screen and scanned documents.
class PdfEditorLauncher {
  static Uint8List? _font;

  static Future<Uint8List> _unicodeFont() async {
    final f = _font;
    if (f != null) return f;
    final d = await rootBundle.load('assets/fonts/FreeSans.ttf');
    return _font = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  /// Opens [bytes] for editing. A recoverable draft for the same library
  /// document is offered first.
  static Future<void> open(BuildContext context, Uint8List bytes, String title, {String? docId, String? password}) async {
    if (docId != null) {
      final existing = await EditorDraft.forDocument(docId);
      if (existing != null && context.mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unsaved edits found'),
            content: Text('You have edits to "${existing.title}" from ${formatDateTime(existing.updated)} that were not saved. Continue with them?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard them')),
              FilledButton(onPressed: () => Navigator.pop(ctx, 'resume'), child: const Text('Continue editing')),
            ],
          ),
        );
        if (choice == null || !context.mounted) return;
        if (choice == 'resume') return resume(context, existing);
        await existing.delete();
      }
    }
    if (!context.mounted) return;
    final draft = await EditorDraft.create(bytes, title: title, docId: docId, encrypted: password != null && password.isNotEmpty);
    if (!context.mounted) return;
    final ok = await _start(context, draft, password: password, initial: null);
    if (!ok) await draft.delete();
  }

  static Future<void> resume(BuildContext context, EditorDraft draft) async {
    final state = await draft.loadState();
    if (!context.mounted) return;
    await _start(context, draft, password: null, initial: state);
  }

  static Future<void> pickAndOpen(BuildContext context) async {
    try {
      final picked = await PdfLibrary.pickPdfs();
      if (picked.isEmpty || !context.mounted) return;
      final (bytes, name) = picked.first;
      await open(context, bytes, name);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }
  }

  /// Opens the engine (asking for a password if needed) and pushes the
  /// editor. Returns false when the user cancelled or opening failed.
  static Future<bool> _start(BuildContext context, EditorDraft draft, {String? password, EditState? initial}) async {
    final bytes = await draft.originalFile.readAsBytes();
    final font = await _unicodeFont();
    EditorEngineClient? client;
    var pw = password;
    for (var attempt = 0; attempt < 6 && client == null; attempt++) {
      if (!context.mounted) return false;
      try {
        client = await runBusy(context, 'Opening PDF…', (_) => EditorEngineClient.open(bytes, font, password: pw), rethrowErrors: true);
      } on EditorPasswordRequired catch (e) {
        if (!context.mounted) return false;
        pw = await promptText(context, e.wrong ? 'Incorrect password, try again' : '"${draft.title}" is password protected',
            hint: 'PDF password', obscure: true, ok: 'Open');
        if (pw == null) return false;
      } on EditorPermissionDenied catch (e) {
        if (context.mounted) await showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: const Text('Editing not allowed'), content: Text(e.toString()), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]));
        return false;
      } catch (e) {
        if (context.mounted) showSnack(context, friendlyError(e));
        return false;
      }
    }
    if (client == null || !context.mounted) {
      client?.close();
      return false;
    }
    var start = initial;
    if (start != null && start.slots.any((s) => s.source != null && s.source! >= client!.pageCount)) {
      start = null; // the draft does not match the file; start fresh
    }
    final c = PdfEditorController(
      engine: client,
      draft: draft,
      title: draft.title,
      docId: draft.docId,
      password: pw,
      initial: start ?? EditState.initial(client.pageCount),
    );
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfEditorScreen(controller: c)));
    return true;
  }
}

/// Editing drafts that were not saved (kept after the app closed or was
/// killed).
class EditorDraftsScreen extends StatefulWidget {
  const EditorDraftsScreen({super.key});
  @override
  State<EditorDraftsScreen> createState() => _EditorDraftsScreenState();
}

class _EditorDraftsScreenState extends State<EditorDraftsScreen> {
  List<EditorDraft>? _drafts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await EditorDraft.list();
    if (mounted) setState(() => _drafts = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _drafts;
    return Scaffold(
      appBar: AppBar(title: const Text('Unfinished PDF edits')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : d.isEmpty
              ? const EmptyState(icon: Icons.edit_document, title: 'No unfinished edits', message: 'Edits you leave without saving are kept here so you can continue later.')
              : ListView(children: [
                  for (final x in d)
                    ListTile(
                      leading: Icon(x.encrypted ? Icons.lock_outline : Icons.edit_document),
                      title: Text(x.title),
                      subtitle: Text('Last edited ${formatDateTime(x.updated)}${x.encrypted ? ' · password needed' : ''}'),
                      onTap: () async {
                        await PdfEditorLauncher.resume(context, x);
                        await _load();
                      },
                      trailing: IconButton(
                        tooltip: 'Discard',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (await confirm(context, 'Discard these edits?', 'The draft is deleted. The original file is not affected.', ok: 'Discard', destructive: true)) {
                            await x.delete();
                            await _load();
                          }
                        },
                      ),
                    ),
                ]),
    );
  }
}
