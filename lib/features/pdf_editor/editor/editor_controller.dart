import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/ids.dart';
import '../engine/engine_worker.dart';
import '../engine/pdf_edit_engine.dart';
import '../model/edit_state.dart';
import 'editor_draft.dart';

/// The editor's working modes (toolbar sections).
enum EditorTool { editText, addText, editImage, annotate, stamp }

/// Sub-tools of Annotate.
enum AnnotTool { select, highlight, underline, strikeout, pen, note, rect, ellipse, line, arrow }

extension AnnotToolInfo on AnnotTool {
  String get label => switch (this) {
        AnnotTool.select => 'Select',
        AnnotTool.highlight => 'Highlight',
        AnnotTool.underline => 'Underline',
        AnnotTool.strikeout => 'Strike',
        AnnotTool.pen => 'Pen',
        AnnotTool.note => 'Note',
        AnnotTool.rect => 'Rectangle',
        AnnotTool.ellipse => 'Ellipse',
        AnnotTool.line => 'Line',
        AnnotTool.arrow => 'Arrow',
      };
  bool get draws => this != AnnotTool.select && this != AnnotTool.note;
}

/// What is selected on the page.
class Selection {
  final String? itemId; // an added item
  final String? blockKey; // an existing text block
  final String? imageKey; // an existing image object
  const Selection.item(String id)
      : itemId = id,
        blockKey = null,
        imageKey = null;
  const Selection.block(String key)
      : itemId = null,
        blockKey = key,
        imageKey = null;
  const Selection.image(String key)
      : itemId = null,
        blockKey = null,
        imageKey = key;
}

class PdfEditorController extends ChangeNotifier {
  final EditorEngineClient engine;
  final EditorDraft draft;
  final String title;
  final String? docId; // library document being edited (if any)
  final String? password;
  final EditHistory history;
  final DraftAutosaver _autosaver;
  EditState _saved; // state at the last successful save

  PdfEditorController({required this.engine, required this.draft, required this.title, required this.docId, required this.password, required EditState initial, EditState? baseline})
      : history = EditHistory(initial),
        _autosaver = DraftAutosaver(draft),
        _saved = baseline ?? EditState.initial(engine.pageCount);

  EditState get state => history.current;
  bool get dirty => !identical(state, _saved) && !(state.isPristine && _saved.isPristine);

  // ---------------------------------------------------------------- pages
  int _page = 0;
  int get pageIndex => _page.clamp(0, math0(state.slots.length - 1));
  PageSlot get slot => state.slots[pageIndex];
  int get pageCount => state.slots.length;

  final Map<String, Size> _sizes = {};
  Size? get slotSize => _sizes[slot.id];

  final Map<int, PageAnalysis> _analysis = {};
  PageAnalysis? get analysis => slot.source == null ? null : _analysis[slot.source];

  Future<void> goTo(int index) async {
    if (index < 0 || index >= state.slots.length) return;
    _page = index;
    selection = null;
    notifyListeners();
    await _loadPage();
  }

  Future<PageAnalysis?> analysisFor(PageSlot s) async {
    final src = s.source;
    if (src == null) return null;
    final a = _analysis[src];
    if (a != null) return a;
    final r = await engine.analyze(src);
    _analysis[src] = r;
    return r;
  }

  // ---------------------------------------------------------------- render
  ui.Image? image;
  bool showOriginal = false;
  double renderScale = 2;
  String? renderError;
  bool rendering = false;
  int _gen = 0;

  Future<void> start() async {
    await _loadPage();
  }

  Future<void> _loadPage() async {
    final s = slot;
    try {
      _sizes[s.id] ??= await engine.slotSize(state, s.id);
      await analysisFor(s);
    } catch (e) {
      renderError = e.toString();
    }
    notifyListeners();
    await refresh();
  }

  Future<void> refresh() async {
    final gen = ++_gen;
    final s = slot;
    rendering = true;
    notifyListeners();
    try {
      final r = await engine.render(state, s.id, renderScale, original: showOriginal, draftDir: draft.dir);
      if (gen != _gen) return;
      final img = await _decode(r);
      if (gen != _gen) {
        img.dispose();
        return;
      }
      image?.dispose();
      image = img;
      renderError = null;
    } catch (e) {
      if (gen == _gen) renderError = e.toString();
    } finally {
      if (gen == _gen) {
        rendering = false;
        notifyListeners();
      }
    }
  }

  static Future<ui.Image> _decode(RenderedPage r) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(r.rgba, r.width, r.height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  void setRenderScale(double s) {
    // Cap the bitmap at about 12 megapixels to bound memory use.
    final size = slotSize;
    final cap = size == null || size.isEmpty ? 4.0 : math.min(4.0, math.sqrt(12e6 / (size.width * size.height)));
    final v = s.clamp(1.0, math.max(1.0, cap)).toDouble();
    if ((v - renderScale).abs() < 0.25) return;
    renderScale = v;
    refresh();
  }

  void toggleOriginal() {
    showOriginal = !showOriginal;
    selection = null;
    notifyListeners();
    refresh();
  }

  // Thumbnails for the pages view.
  final Map<String, ui.Image> _thumbs = {};
  final Map<String, Future<ui.Image?>> _thumbJobs = {};
  int _version = 0;

  Future<ui.Image?> thumbnail(PageSlot s) {
    final key = '${s.id}@${state.slotHasContentEdits(s) || !state.decorations.isEmpty ? _version : 0}';
    final hit = _thumbs[key];
    if (hit != null) return Future.value(hit);
    return _thumbJobs.putIfAbsent(key, () async {
      try {
        final r = await engine.render(state, s.id, 0.22, draftDir: draft.dir);
        final img = await _decode(r);
        if (_thumbs.length > 80) {
          final k = _thumbs.keys.first;
          _thumbs.remove(k)?.dispose();
        }
        _thumbs[key] = img;
        return img;
      } catch (_) {
        return null;
      } finally {
        _thumbJobs.remove(key);
      }
    });
  }

  // ---------------------------------------------------------------- tools
  EditorTool tool = EditorTool.editText;
  AnnotTool annotTool = AnnotTool.highlight;
  int annotColor = 0xFFFFEB3B;
  double strokeWidth = 2;
  Selection? selection;

  void setTool(EditorTool t) {
    tool = t;
    selection = null;
    if (showOriginal) {
      showOriginal = false;
      refresh();
    }
    notifyListeners();
  }

  void setAnnotTool(AnnotTool t) {
    annotTool = t;
    selection = null;
    annotColor = switch (t) {
      AnnotTool.highlight => 0xFFFFEB3B,
      AnnotTool.underline => 0xFF1565C0,
      AnnotTool.strikeout => 0xFFC62828,
      AnnotTool.note => 0xFFFFC107,
      _ => annotColor == 0xFFFFEB3B ? 0xFFC62828 : annotColor,
    };
    notifyListeners();
  }

  void select(Selection? s) {
    selection = s;
    notifyListeners();
  }

  EditItem? get selectedItem {
    final id = selection?.itemId;
    if (id == null) return null;
    for (final i in state.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  TextBlockInfo? get selectedBlock {
    final k = selection?.blockKey;
    final a = analysis;
    if (k == null || a == null) return null;
    for (final b in a.blocks) {
      if (b.key == k) return b;
    }
    return null;
  }

  ImageObjInfo? get selectedImage {
    final k = selection?.imageKey;
    final a = analysis;
    if (k == null || a == null) return null;
    for (final i in a.images) {
      if (i.key == k) return i;
    }
    return null;
  }

  // ---------------------------------------------------------------- edits
  /// Applies a new state. [transient] updates without a history entry
  /// (used while dragging; call [commit] at the end).
  void apply(EditState next, {bool transient = false, bool render = true}) {
    if (transient) {
      history.replace(next);
    } else {
      history.push(next);
      _autosaver.schedule(next);
    }
    _version++;
    notifyListeners();
    if (render) refresh();
  }

  EditState? _dragStart;
  void beginDrag() => _dragStart = state;
  void commitDrag() {
    final start = _dragStart;
    _dragStart = null;
    if (start == null || identical(start, state)) {
      refresh();
      return;
    }
    final end = state;
    history.replace(start);
    apply(end);
  }

  void undo() {
    history.undo();
    _afterHistory();
  }

  void redo() {
    history.redo();
    _afterHistory();
  }

  void _afterHistory() {
    _autosaver.schedule(state);
    selection = null;
    if (_page >= state.slots.length) _page = state.slots.length - 1;
    _version++;
    notifyListeners();
    _loadPage();
  }

  String newItemId() => newId();

  EditItem addItem(EditItem item) {
    apply(state.withItem(item));
    selection = Selection.item(item.id);
    notifyListeners();
    return item;
  }

  void deleteSelection() {
    final s = selection;
    if (s == null) return;
    if (s.itemId != null) {
      apply(state.withoutItem(s.itemId!));
    } else if (s.blockKey != null) {
      final b = selectedBlock;
      if (b != null) apply(state.withTextEdit(TextBlockEdit(page: b.page, objects: b.objects, deleted: true)));
    } else if (s.imageKey != null) {
      final i = selectedImage;
      if (i != null) apply(state.withImageEdit((state.imageEdits[i.key] ?? ImageObjEdit(page: i.page, object: i.object)).copyWith(deleted: true)));
    }
    selection = null;
    notifyListeners();
  }

  void duplicateSelection() {
    final it = selectedItem;
    if (it == null) return;
    addItem(it.translated(const Offset(14, 14)).copyWith(id: newId()));
  }

  /// Current box of an existing block (edited or original).
  Rect blockBox(TextBlockInfo b) => state.textEdits[b.key]?.box ?? b.bounds;
  Rect imageBox(ImageObjInfo i) => state.imageEdits[i.key]?.box ?? i.bounds;

  void revertBlock(TextBlockInfo b) => apply(state.withoutTextEdit(b.key));
  void revertImage(ImageObjInfo i) => apply(state.withoutImageEdit(i.key));

  Future<TextEditReport> previewTextEdit(TextBlockEdit e) => engine.previewTextEdit(e);

  // ---------------------------------------------------------------- saving
  Future<ExportResult> export(ExportOptions o) async {
    await _autosaver.flush();
    return engine.export(state, o, draft.dir);
  }

  void markSaved() {
    _saved = state;
    notifyListeners();
  }

  Future<void> flushDraft() => _autosaver.flush();

  @override
  void dispose() {
    _autosaver.flush();
    image?.dispose();
    for (final t in _thumbs.values) {
      t.dispose();
    }
    engine.close();
    super.dispose();
  }
}

int math0(int v) => v < 0 ? 0 : v;
