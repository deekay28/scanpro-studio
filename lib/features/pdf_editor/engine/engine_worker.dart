import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import '../model/edit_state.dart';
import 'host_ops.dart';
import 'pdf_edit_engine.dart';
import 'pdfium_engine.dart';

/// A rendered page in RGBA.
class RenderedPage {
  final Uint8List rgba;
  final int width;
  final int height;
  const RenderedPage(this.rgba, this.width, this.height);
}

class _Err {
  final Object error;
  const _Err(this.error);
}

Object _sendable(Object e) => e is EditorPasswordRequired || e is EditorPermissionDenied || e is PdfEditException ? e : PdfEditException(e.toString());

/// The app-wide PDFium host: one background isolate that owns PDFium for the
/// whole process. PDFium is not thread-safe, so every PDF operation in the
/// app (editor, reader, converters, security tools) runs here, one request
/// at a time, while the UI stays responsive.
class PdfiumHost {
  final SendPort _send;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 1;

  PdfiumHost._(this._send);

  static Future<PdfiumHost>? _instance;

  /// The running host, started on first use with the bundled Unicode font.
  static Future<PdfiumHost> start(Uint8List unicodeFont) => _instance ??= _spawn(unicodeFont);

  static Future<PdfiumHost> _spawn(Uint8List font) async {
    final receive = ReceivePort();
    await Isolate.spawn(_hostMain, (receive.sendPort, font, PdfiumEngine.modulePath), debugName: 'pdfium-host');
    final events = StreamIterator(receive);
    await events.moveNext();
    final host = PdfiumHost._(events.current as SendPort);
    () async {
      while (await events.moveNext()) {
        final (id, value) = events.current as (int, Object?);
        final c = host._pending.remove(id);
        if (c == null) continue;
        if (value is _Err) {
          c.completeError(value.error);
        } else {
          c.complete(value);
        }
      }
    }();
    return host;
  }

  Future<T> call<T>(String op, int session, List<Object?> args) {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send((id, op, session, args));
    return c.future.then((v) => v as T);
  }

  /// Opens a document. Throws [EditorPasswordRequired],
  /// [EditorPermissionDenied] or [PdfEditException].
  Future<HostSession> open(Uint8List bytes, {String? password}) async {
    final (sid, count, enc, title) = await call<(int, int, bool, String?)>('open', 0, [bytes, password]);
    return HostSession._(this, sid, count, enc, title, password);
  }

  /// Runs a stateless operation (see host_ops.dart).
  Future<T> run<T>(String op, List<Object?> args) => call<T>(op, 0, args);
}

/// One open document on the host.
class HostSession {
  final PdfiumHost host;
  final int id;
  final int pageCount;
  final bool encrypted;
  final String? title;
  final String? password;
  bool _closed = false;

  HostSession._(this.host, this.id, this.pageCount, this.encrypted, this.title, this.password);

  Future<T> call<T>(String op, [List<Object?> args = const []]) {
    if (_closed) return Future.error(const PdfEditException('The document was closed.'));
    return host.call<T>(op, id, args);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    host.call<Object?>('close', id, const []);
  }
}

/// The editor's view of a host session.
class EditorEngineClient {
  final HostSession session;
  EditorEngineClient._(this.session);

  int get pageCount => session.pageCount;
  bool get encrypted => session.encrypted;
  String? get title => session.title;

  static Future<EditorEngineClient> open(Uint8List bytes, Uint8List unicodeFont, {String? password}) async {
    final host = await PdfiumHost.start(unicodeFont);
    return EditorEngineClient._(await host.open(bytes, password: password));
  }

  Future<PageAnalysis> analyze(int page) => session.call('analyze', [page]);
  Future<Size> slotSize(EditState s, String slot) => session.call('slotSize', [s, slot]);
  Future<RenderedPage> render(EditState s, String slot, double scale, {bool original = false, String draftDir = ''}) =>
      session.call('render', [s, slot, scale, original, draftDir]);
  Future<TextEditReport> previewTextEdit(TextBlockEdit e) => session.call('preview', [e]);
  Future<ExportResult> export(EditState s, ExportOptions o, String draftDir) => session.call('export', [s, o, draftDir]);
  Future<List<String>> pageTexts(Uint8List bytes, String? password) => session.host.run('texts', [bytes, password]);

  void close() => session.close();
}

// ---------------------------------------------------------------------------
// Host isolate
// ---------------------------------------------------------------------------

void _hostMain((SendPort, Uint8List, String?) init) {
  final (out, font, modulePath) = init;
  if (modulePath != null) PdfiumEngine.modulePath = modulePath;
  final engine = PdfiumEngine(unicodeFont: font);
  final sessions = <int, PdfiumSession>{};
  var nextSession = 1;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((msg) {
    final (id, op, sid, args) = msg as (int, String, int, List<Object?>);
    try {
      Object? result;
      switch (op) {
        case 'open':
          final s = engine.open(args[0] as Uint8List, password: args[1] as String?) as PdfiumSession;
          final n = nextSession++;
          sessions[n] = s;
          result = (n, s.pageCount, s.encrypted, s.title);
        case 'close':
          sessions.remove(sid)?.close();
        default:
          final s = sid == 0 ? null : sessions[sid];
          if (sid != 0 && s == null) throw const PdfEditException('The document is no longer open.');
          result = switch (op) {
            'analyze' => s!.analyze(args[0] as int),
            'slotSize' => s!.slotSize(args[0] as EditState, args[1] as String),
            'render' => () {
                final r = s!.render(args[0] as EditState, args[1] as String, args[2] as double, original: args[3] as bool, draftDir: args[4] as String);
                return RenderedPage(r.rgba, r.width, r.height);
              }(),
            'preview' => s!.previewTextEdit(args[0] as TextBlockEdit),
            'export' => s!.export(args[0] as EditState, options: args[1] as ExportOptions, draftDir: args[2] as String),
            'texts' => PdfiumSession.pageTexts(args[0] as Uint8List, password: args[1] as String?),
            _ => runHostOp(op, s, args, engine),
          };
      }
      out.send((id, result));
    } catch (e) {
      out.send((id, _Err(_sendable(e))));
    }
  });
}
