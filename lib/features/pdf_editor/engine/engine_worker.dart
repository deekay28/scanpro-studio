import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import '../model/edit_state.dart';
import 'pdf_edit_engine.dart';
import 'pdfium_engine.dart';

/// A rendered page in RGBA.
class RenderedPage {
  final Uint8List rgba;
  final int width;
  final int height;
  const RenderedPage(this.rgba, this.width, this.height);
}

/// Runs the PDF engine on its own isolate so rendering and exporting large
/// documents never blocks the UI. PDFium is not thread-safe; this isolate
/// is its only user while the editor is open.
class EditorEngineClient {
  final SendPort _send;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;
  bool _closed = false;

  final int pageCount;
  final bool encrypted;
  final String? title;

  EditorEngineClient._(this._send, this.pageCount, this.encrypted, this.title);

  /// Opens [bytes] on a new worker isolate. Throws [EditorPasswordRequired],
  /// [EditorPermissionDenied] or [PdfEditException].
  static Future<EditorEngineClient> open(Uint8List bytes, Uint8List unicodeFont, {String? password}) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, receive.sendPort, debugName: 'pdf-editor-engine');
    final events = StreamIterator(receive);
    await events.moveNext();
    final send = events.current as SendPort;
    send.send(('open', bytes, unicodeFont, password, PdfiumEngine.modulePath));
    await events.moveNext();
    final reply = events.current;
    if (reply is _Err) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      throw reply.error;
    }
    final (count, enc, title) = reply as (int, bool, String?);
    final c = EditorEngineClient._(send, count, enc, title);
    // Remaining messages are replies.
    () async {
      while (await events.moveNext()) {
        final (id, value) = events.current as (int, Object?);
        if (id == -1) {
          // The worker closed the document; it can be stopped now.
          receive.close();
          isolate.kill();
          break;
        }
        final cpl = c._pending.remove(id);
        if (cpl == null) continue;
        if (value is _Err) {
          cpl.completeError(value.error);
        } else {
          cpl.complete(value);
        }
      }
    }();
    return c;
  }

  Future<T> _call<T>(String method, List<Object?> args) {
    if (_closed) return Future.error(const PdfEditException('The editor was closed.'));
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send((id, method, args));
    return c.future.then((v) => v as T);
  }

  Future<PageAnalysis> analyze(int page) => _call('analyze', [page]);
  Future<Size> slotSize(EditState s, String slot) => _call('slotSize', [s, slot]);
  Future<RenderedPage> render(EditState s, String slot, double scale, {bool original = false, String draftDir = ''}) =>
      _call('render', [s, slot, scale, original, draftDir]);
  Future<TextEditReport> previewTextEdit(TextBlockEdit e) => _call('preview', [e]);
  Future<ExportResult> export(EditState s, ExportOptions o, String draftDir) => _call('export', [s, o, draftDir]);
  Future<List<String>> pageTexts(Uint8List bytes, String? password) => _call('texts', [bytes, password]);

  void close() {
    if (_closed) return;
    _closed = true;
    _send.send((-1, 'close', const <Object?>[]));
    for (final c in _pending.values) {
      c.completeError(const PdfEditException('The editor was closed.'));
    }
    _pending.clear();
  }
}

class _Err {
  final Object error;
  const _Err(this.error);
}

Object _sendable(Object e) => e is EditorPasswordRequired || e is EditorPermissionDenied || e is PdfEditException ? e : PdfEditException(e.toString());

void _workerMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  PdfEditSession? session;
  inbox.listen((msg) {
    if (msg is (String, Uint8List, Uint8List, String?, String?)) {
      final (_, bytes, font, password, modulePath) = msg;
      try {
        if (modulePath != null) PdfiumEngine.modulePath = modulePath;
        final s = PdfiumEngine(unicodeFont: font).open(bytes, password: password);
        session = s;
        out.send((s.pageCount, s.encrypted, s.title));
      } catch (e) {
        out.send(_Err(_sendable(e)));
      }
      return;
    }
    final (id, method, args) = msg as (int, String, List<Object?>);
    final s = session;
    if (method == 'close') {
      s?.close();
      session = null;
      inbox.close();
      out.send((-1, null));
      return;
    }
    try {
      if (s == null) throw const PdfEditException('No document is open.');
      final Object result = switch (method) {
        'analyze' => s.analyze(args[0] as int),
        'slotSize' => s.slotSize(args[0] as EditState, args[1] as String),
        'render' => () {
            final r = s.render(args[0] as EditState, args[1] as String, args[2] as double, original: args[3] as bool, draftDir: args[4] as String);
            return RenderedPage(r.rgba, r.width, r.height);
          }(),
        'preview' => s.previewTextEdit(args[0] as TextBlockEdit),
        'export' => s.export(args[0] as EditState, options: args[1] as ExportOptions, draftDir: args[2] as String),
        'texts' => PdfiumSession.pageTexts(args[0] as Uint8List, password: args[1] as String?),
        _ => throw PdfEditException('Unknown engine call $method'),
      };
      out.send((id, result));
    } catch (e) {
      out.send((id, _Err(_sendable(e))));
    }
  });
}
