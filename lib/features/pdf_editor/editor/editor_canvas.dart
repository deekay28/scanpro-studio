import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/pdf_edit_engine.dart';
import '../model/edit_state.dart';
import 'editor_controller.dart';

/// Called when the user taps an empty spot in a tool that places things.
typedef PlaceCallback = void Function(Offset pagePoint);

/// The page with its selection overlay. Positions are converted from screen
/// pixels to page points (display points) with the fit scale `k`.
class EditorCanvas extends StatefulWidget {
  final PdfEditorController c;
  final PlaceCallback onPlaceText;
  final PlaceCallback onPlaceNote;
  final void Function(TextBlockInfo b) onEditBlock;
  final void Function(EditItem item) onEditItem;
  const EditorCanvas({super.key, required this.c, required this.onPlaceText, required this.onPlaceNote, required this.onEditBlock, required this.onEditItem});

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

enum _Drag { none, move, resize, draw }

class _EditorCanvasState extends State<EditorCanvas> {
  final _tc = TransformationController();
  double _k = 1;
  _Drag _drag = _Drag.none;
  Offset _start = Offset.zero;
  Rect _startBox = Rect.zero;
  List<Offset> _draw = [];

  PdfEditorController get c => widget.c;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  bool get _drawingTool => c.tool == EditorTool.annotate && c.annotTool.draws;

  // ------------------------------------------------------------ geometry
  Rect? _selectedBox() {
    final it = c.selectedItem;
    if (it != null) return it.box;
    final b = c.selectedBlock;
    if (b != null) return c.blockBox(b);
    final i = c.selectedImage;
    if (i != null) return c.imageBox(i);
    return null;
  }

  bool _keepAspect() {
    final it = c.selectedItem;
    if (it != null) return it.kind == ItemKind.image || it.kind == ItemKind.stamp;
    return c.selectedImage != null;
  }

  double get _handle => 22 / _k / _tc.value.getMaxScaleOnAxis();

  bool _nearHandle(Offset p, Rect box) {
    final it = c.selectedItem;
    final textLike = c.selectedBlock != null || (it != null && it.kind == ItemKind.text);
    final h = textLike ? Offset(box.right, box.center.dy) : box.bottomRight;
    return (p - h).distance <= _handle;
  }

  List<EditItem> _itemsForTool() {
    final items = c.state.itemsOn(c.slot.id);
    bool want(EditItem i) => switch (c.tool) {
          EditorTool.editText || EditorTool.addText => i.kind == ItemKind.text,
          EditorTool.editImage => i.kind == ItemKind.image,
          EditorTool.annotate => i.kind.isAnnotation && i.kind != ItemKind.stamp,
          EditorTool.stamp => i.kind == ItemKind.stamp,
        };
    return items.where(want).toList();
  }

  Selection? _hit(Offset p) {
    final tol = 6 / _k;
    for (final it in _itemsForTool().reversed) {
      if (it.box.inflate(tol).contains(p)) return Selection.item(it.id);
    }
    final a = c.analysis;
    if (a == null) return null;
    if (c.tool == EditorTool.editText) {
      TextBlockInfo? best;
      for (final b in a.blocks) {
        final e = c.state.textEdits[b.key];
        if (e != null && e.deleted) continue;
        final box = c.blockBox(b).inflate(3);
        if (box.contains(p) && (best == null || box.width * box.height < c.blockBox(best).width * c.blockBox(best).height)) best = b;
      }
      if (best != null) return Selection.block(best.key);
    }
    if (c.tool == EditorTool.editImage) {
      for (final i in a.images.reversed) {
        final e = c.state.imageEdits[i.key];
        if (e != null && e.deleted) continue;
        if (c.imageBox(i).contains(p)) return Selection.image(i.key);
      }
    }
    return null;
  }

  // ------------------------------------------------------------ gestures
  void _onTap(Offset p) {
    final hit = _hit(p);
    if (hit != null) {
      final same = c.selection?.itemId == hit.itemId && c.selection?.blockKey == hit.blockKey && c.selection?.imageKey == hit.imageKey;
      c.select(hit);
      if (same) {
        // Second tap opens the editor for text.
        final b = c.selectedBlock;
        if (b != null) widget.onEditBlock(b);
        final it = c.selectedItem;
        if (it != null && (it.kind == ItemKind.text || it.kind == ItemKind.note)) widget.onEditItem(it);
      }
      return;
    }
    if (c.selection != null) {
      c.select(null);
      return;
    }
    if (c.tool == EditorTool.addText) widget.onPlaceText(p);
    if (c.tool == EditorTool.annotate && c.annotTool == AnnotTool.note) widget.onPlaceNote(p);
  }

  void _onPanStart(Offset p) {
    final box = _selectedBox();
    if (box != null && _nearHandle(p, box)) {
      _drag = _Drag.resize;
    } else if (box != null && box.inflate(6 / _k).contains(p)) {
      _drag = _Drag.move;
    } else if (_drawingTool) {
      _drag = _Drag.draw;
      _draw = [p];
      setState(() {});
      return;
    } else {
      _drag = _Drag.none;
      return;
    }
    _start = p;
    _startBox = box;
    c.beginDrag();
  }

  void _onPanUpdate(Offset p) {
    switch (_drag) {
      case _Drag.draw:
        setState(() => _draw.add(p));
      case _Drag.move:
        _setBox(_startBox.shift(p - _start));
      case _Drag.resize:
        final d = p - _start;
        Rect r;
        final it = c.selectedItem;
        final textLike = c.selectedBlock != null || (it != null && it.kind == ItemKind.text);
        if (textLike) {
          r = Rect.fromLTWH(_startBox.left, _startBox.top, math.max(12, _startBox.width + d.dx), _startBox.height);
        } else if (_keepAspect()) {
          final s = math.max(0.05, (_startBox.width + d.dx) / _startBox.width);
          r = Rect.fromLTWH(_startBox.left, _startBox.top, _startBox.width * s, _startBox.height * s);
        } else {
          r = Rect.fromLTWH(_startBox.left, _startBox.top, math.max(4, _startBox.width + d.dx), math.max(4, _startBox.height + d.dy));
        }
        _setBox(r);
      case _Drag.none:
        break;
    }
  }

  void _setBox(Rect r) {
    final s = c.state;
    final it = c.selectedItem;
    if (it != null) {
      final next = _drag == _Drag.move ? it.translated(r.topLeft - it.box.topLeft) : it.resized(r);
      c.apply(s.withItem(next), transient: true, render: false);
      return;
    }
    final b = c.selectedBlock;
    if (b != null) {
      final e = s.textEdits[b.key] ?? TextBlockEdit(page: b.page, objects: b.objects);
      c.apply(s.withTextEdit(e.copyWith(box: r, text: e.text ?? b.text, style: e.style ?? b.originalStyle)), transient: true, render: false);
      return;
    }
    final i = c.selectedImage;
    if (i != null) {
      final e = s.imageEdits[i.key] ?? ImageObjEdit(page: i.page, object: i.object);
      c.apply(s.withImageEdit(e.copyWith(box: r)), transient: true, render: false);
    }
  }

  void _onPanEnd() {
    if (_drag == _Drag.draw) {
      _finishDrawing();
    } else if (_drag != _Drag.none) {
      c.commitDrag();
    }
    _drag = _Drag.none;
    setState(() => _draw = []);
  }

  void _finishDrawing() {
    final pts = _draw;
    if (pts.length < 2) return;
    final rect = Rect.fromPoints(pts.first, pts.last);
    final bounds = pts.fold<Rect>(Rect.fromCenter(center: pts.first, width: 0, height: 0), (r, p) => r.expandToInclude(Rect.fromCenter(center: p, width: 0, height: 0)));
    final color = c.annotColor;
    final id = c.newItemId();
    final slot = c.slot.id;
    switch (c.annotTool) {
      case AnnotTool.highlight:
      case AnnotTool.underline:
      case AnnotTool.strikeout:
        final rects = _textRects(rect);
        final kind = {AnnotTool.highlight: ItemKind.highlight, AnnotTool.underline: ItemKind.underline, AnnotTool.strikeout: ItemKind.strikeout}[c.annotTool]!;
        final area = rects.isEmpty ? [Rect.fromLTRB(rect.left, rect.top, rect.right, math.max(rect.bottom, rect.top + 10))] : rects;
        c.addItem(EditItem(id: id, slot: slot, kind: kind, box: area.reduce((a, b) => a.expandToInclude(b)), rects: area, color: color));
      case AnnotTool.pen:
        c.addItem(EditItem(id: id, slot: slot, kind: ItemKind.ink, box: bounds, strokes: [pts], color: color, strokeWidth: c.strokeWidth));
      case AnnotTool.rect:
      case AnnotTool.ellipse:
        if (rect.width < 4 || rect.height < 4) return;
        c.addItem(EditItem(id: id, slot: slot, kind: c.annotTool == AnnotTool.rect ? ItemKind.rect : ItemKind.ellipse, box: rect, color: color, strokeWidth: c.strokeWidth));
      case AnnotTool.line:
      case AnnotTool.arrow:
        c.addItem(EditItem(
            id: id,
            slot: slot,
            kind: c.annotTool == AnnotTool.line ? ItemKind.line : ItemKind.arrow,
            box: rect,
            strokes: [
              [pts.first, pts.last]
            ],
            color: color,
            strokeWidth: c.strokeWidth));
      default:
        break;
    }
  }

  /// Line-level rectangles of the text touched by a drag from the top-left
  /// to bottom-right of [sel]; first and last lines are clipped to where the
  /// drag started/ended.
  List<Rect> _textRects(Rect sel) {
    final a = c.analysis;
    if (a == null) return const [];
    final lines = <List<TextRunInfo>>[];
    for (final b in a.blocks) {
      for (final l in b.lines) {
        final r = l.map((e) => e.bounds).reduce((x, y) => x.expandToInclude(y));
        if (r.bottom >= sel.top && r.top <= sel.bottom && r.right >= sel.left - 2 && (sel.height > r.height || r.left <= sel.right)) lines.add(l);
      }
    }
    lines.sort((x, y) => x.first.bounds.top.compareTo(y.first.bounds.top));
    final out = <Rect>[];
    for (var i = 0; i < lines.length; i++) {
      var r = lines[i].map((e) => e.bounds).reduce((x, y) => x.expandToInclude(y));
      if (lines.length == 1) {
        r = Rect.fromLTRB(math.max(r.left, sel.left), r.top, math.min(r.right, sel.right), r.bottom);
      } else if (i == 0) {
        r = Rect.fromLTRB(math.max(r.left, sel.left), r.top, r.right, r.bottom);
      } else if (i == lines.length - 1) {
        r = Rect.fromLTRB(r.left, r.top, math.min(r.right, sel.right), r.bottom);
      }
      if (r.width > 1) out.add(r);
    }
    return out;
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final size = c.slotSize;
    final img = c.image;
    if (size == null || img == null) {
      return Center(child: c.renderError != null ? Padding(padding: const EdgeInsets.all(24), child: Text(c.renderError!)) : const CircularProgressIndicator());
    }
    final interactive = c.selection != null || _drawingTool;
    return LayoutBuilder(builder: (context, box) {
      _k = math.min(box.maxWidth / size.width, box.maxHeight / size.height) * 0.97;
      final w = size.width * _k, h = size.height * _k;
      Offset toPage(Offset local) => local / _k;
      return InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 8,
        panEnabled: !interactive,
        scaleEnabled: !_drawingTool,
        boundaryMargin: const EdgeInsets.all(80),
        onInteractionEnd: (_) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          c.setRenderScale(_k * dpr * _tc.value.getMaxScaleOnAxis());
        },
        child: Center(
          child: SizedBox(
            key: const ValueKey('editor-page'),
            width: w,
            height: h,
            child: Stack(fit: StackFit.expand, children: [
              DecoratedBox(
                decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
                child: RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              ),
              if (!c.showOriginal)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onTap(toPage(d.localPosition)),
                  onPanStart: interactive ? (d) => _onPanStart(toPage(d.localPosition)) : null,
                  onPanUpdate: interactive ? (d) => _onPanUpdate(toPage(d.localPosition)) : null,
                  onPanEnd: interactive ? (_) => _onPanEnd() : null,
                  child: CustomPaint(painter: _Overlay(this, _k)),
                ),
              if (c.rendering) const Positioned(right: 6, top: 6, child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ]),
          ),
        ),
      );
    });
  }
}

class _Overlay extends CustomPainter {
  final _EditorCanvasState s;
  final double k;
  _Overlay(this.s, this.k);

  Rect _px(Rect r) => Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k);

  @override
  void paint(Canvas canvas, Size size) {
    final c = s.c;
    final scheme = Colors.blue;
    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = scheme.withValues(alpha: 0.45);
    final a = c.analysis;
    if (a != null && c.tool == EditorTool.editText) {
      for (final b in a.blocks) {
        final e = c.state.textEdits[b.key];
        if (e != null && e.deleted) continue;
        final r = _px(c.blockBox(b).inflate(1.5));
        canvas.drawRect(r, faint..color = (e != null ? Colors.green : scheme).withValues(alpha: 0.5));
      }
    }
    if (a != null && c.tool == EditorTool.editImage) {
      for (final i in a.images) {
        final e = c.state.imageEdits[i.key];
        if (e != null && e.deleted) continue;
        canvas.drawRect(_px(c.imageBox(i)), faint..color = Colors.orange.withValues(alpha: 0.7));
      }
    }
    for (final it in s._itemsForTool()) {
      canvas.drawRect(_px(it.box), faint..color = Colors.purple.withValues(alpha: 0.35));
    }
    // Selection.
    final box = s._selectedBox();
    if (box != null) {
      final r = _px(box);
      canvas.drawRect(r, Paint()..color = scheme.withValues(alpha: 0.08));
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = scheme);
      final it = c.selectedItem;
      final textLike = c.selectedBlock != null || (it != null && it.kind == ItemKind.text);
      final h = textLike ? Offset(r.right, r.center.dy) : r.bottomRight;
      final scale = s._tc.value.getMaxScaleOnAxis();
      canvas.drawCircle(h, 9 / scale, Paint()..color = Colors.white);
      canvas.drawCircle(
          h,
          9 / scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 / scale
            ..color = scheme);
      if (it != null && it.rotation != 0) {
        canvas.drawLine(r.topCenter, r.topCenter - Offset(0, 14 / scale), Paint()..color = scheme);
      }
    }
    // Live drawing.
    final pts = s._draw;
    if (pts.length > 1) {
      final paint = Paint()
        ..color = Color(c.annotColor).withValues(alpha: c.annotTool == AnnotTool.highlight ? 0.4 : 1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, c.strokeWidth * k)
        ..strokeCap = StrokeCap.round;
      switch (c.annotTool) {
        case AnnotTool.pen:
          final path = Path()..moveTo(pts.first.dx * k, pts.first.dy * k);
          for (final p in pts.skip(1)) {
            path.lineTo(p.dx * k, p.dy * k);
          }
          canvas.drawPath(path, paint);
        case AnnotTool.line:
        case AnnotTool.arrow:
          canvas.drawLine(pts.first * k, pts.last * k, paint);
        case AnnotTool.ellipse:
          canvas.drawOval(_px(Rect.fromPoints(pts.first, pts.last)), paint);
        default:
          final r = _px(Rect.fromPoints(pts.first, pts.last));
          canvas.drawRect(r, Paint()..color = Color(c.annotColor).withValues(alpha: 0.25));
          canvas.drawRect(r, paint..strokeWidth = 1);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Overlay old) => true;
}
