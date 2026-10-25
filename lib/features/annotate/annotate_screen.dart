import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../shared/widgets.dart';

/// One annotation element in normalised page coordinates.
class AnnotItem {
  final String type; // ink | highlight | text | sig
  final List<double> points; // ink: x,y pairs; sig: strokes separated by NaN pairs (box-relative)
  final int color;
  final double width; // stroke width as a fraction of page width
  final String text;
  final double x, y; // text/sig top-left
  final double size; // text: font size fraction; sig: box width fraction

  const AnnotItem({
    required this.type,
    this.points = const [],
    this.color = 0xFF1E3A8A,
    this.width = 0.004,
    this.text = '',
    this.x = 0,
    this.y = 0,
    this.size = 0.04,
  });

  AnnotItem moved(double dx, double dy) => AnnotItem(
        type: type,
        points: type == 'ink' || type == 'highlight' ? [for (var i = 0; i < points.length; i++) points[i] + (i.isEven ? dx : dy)] : points,
        color: color,
        width: width,
        text: text,
        x: x + dx,
        y: y + dy,
        size: size,
      );

  AnnotItem resized(double s) => AnnotItem(type: type, points: points, color: color, width: width, text: text, x: x, y: y, size: s);

  Map<String, dynamic> toJson() => {'t': type, 'p': points.map((e) => e.isNaN ? null : e).toList(), 'c': color, 'w': width, 's': text, 'x': x, 'y': y, 'z': size};

  factory AnnotItem.fromJson(Map<String, dynamic> j) => AnnotItem(
        type: j['t'] as String,
        points: ((j['p'] as List?) ?? const []).map((e) => e == null ? double.nan : (e as num).toDouble()).toList(),
        color: (j['c'] as num?)?.toInt() ?? 0xFF000000,
        width: (j['w'] as num?)?.toDouble() ?? 0.004,
        text: j['s'] as String? ?? '',
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        size: (j['z'] as num?)?.toDouble() ?? 0.04,
      );

  /// Bounding box in normalised coordinates (approximate for text).
  Rect bounds(double aspect) {
    if (type == 'text') {
      final h = size * aspect;
      return Rect.fromLTWH(x, y, size * 0.6 * math.max(1, text.length) / 1, h * 1.3);
    }
    if (type == 'sig') return Rect.fromLTWH(x, y, size, size * 0.4 * aspect);
    var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    for (var i = 0; i + 1 < points.length; i += 2) {
      if (points[i].isNaN) continue;
      minX = math.min(minX, points[i]);
      maxX = math.max(maxX, points[i]);
      minY = math.min(minY, points[i + 1]);
      maxY = math.max(maxY, points[i + 1]);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(0.01);
  }
}

class AnnotPainter extends CustomPainter {
  final List<AnnotItem> items;
  final int? selected;
  AnnotPainter(this.items, {this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    for (var idx = 0; idx < items.length; idx++) {
      final it = items[idx];
      final color = Color(it.color);
      switch (it.type) {
        case 'ink':
        case 'highlight':
          {
            final paint = Paint()
              ..color = it.type == 'highlight' ? color.withValues(alpha: 0.35) : color
              ..style = PaintingStyle.stroke
              ..strokeCap = it.type == 'highlight' ? StrokeCap.square : StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = it.width * w;
            final path = Path();
            for (var i = 0; i + 1 < it.points.length; i += 2) {
              final o = Offset(it.points[i] * w, it.points[i + 1] * h);
              if (i == 0) {
                path.moveTo(o.dx, o.dy);
              } else {
                path.lineTo(o.dx, o.dy);
              }
            }
            canvas.drawPath(path, paint);
          }
        case 'text':
          {
            final tp = TextPainter(
              text: TextSpan(text: it.text, style: TextStyle(color: color, fontSize: it.size * w, fontWeight: FontWeight.w600)),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: w * 0.95);
            tp.paint(canvas, Offset(it.x * w, it.y * h));
          }
        case 'sig':
          {
            final bw = it.size * w, bh = bw * 0.4;
            final paint = Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = math.max(1.2, bw * 0.012);
            final path = Path();
            var pen = false;
            for (var i = 0; i + 1 < it.points.length; i += 2) {
              if (it.points[i].isNaN) {
                pen = false;
                continue;
              }
              final o = Offset(it.x * w + it.points[i] * bw, it.y * h + it.points[i + 1] * bh);
              if (!pen) {
                path.moveTo(o.dx, o.dy);
                pen = true;
              } else {
                path.lineTo(o.dx, o.dy);
              }
            }
            canvas.drawPath(path, paint);
          }
      }
      if (selected == idx) {
        final b = it.bounds(h == 0 ? 1 : w / h);
        canvas.drawRect(
          Rect.fromLTRB(b.left * w, b.top * h, b.right * w, b.bottom * h),
          Paint()
            ..color = Colors.blueAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant AnnotPainter old) => true;
}

enum _Tool { pen, highlight, text, move, sign }

/// Annotation editor: pen, highlighter, text, signatures, move/resize and
/// undo. Annotations are stored separately (non-destructive) and burned
/// into exports.
class AnnotateScreen extends ConsumerStatefulWidget {
  final DocPage page;
  const AnnotateScreen({super.key, required this.page});

  @override
  ConsumerState<AnnotateScreen> createState() => _AnnotateScreenState();
}

class _AnnotateScreenState extends ConsumerState<AnnotateScreen> {
  List<AnnotItem> _items = [];
  final List<List<AnnotItem>> _undo = [];
  _Tool _tool = _Tool.pen;
  int _color = 0xFF1E3A8A;
  double _width = 0.004;
  List<double>? _current;
  int? _selected;
  Offset? _lastDrag;
  bool _dirty = false;

  double get _aspect => widget.page.height == 0 ? 0.75 : widget.page.width / widget.page.height;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rel = widget.page.annotPath;
    if (rel == null) return;
    try {
      final j = jsonDecode(await AppStorage.instance.file(rel).readAsString()) as List;
      setState(() => _items = j.map((e) => AnnotItem.fromJson(e as Map<String, dynamic>)).toList());
    } catch (_) {}
  }

  void _push() {
    _undo.add([..._items]);
    if (_undo.length > 50) _undo.removeAt(0);
    _dirty = true;
  }

  Future<void> _addText() async {
    final t = await promptText(context, 'Add text', ok: 'Add');
    if (t == null || t.isEmpty) return;
    _push();
    setState(() {
      _items.add(AnnotItem(type: 'text', text: t, x: 0.1, y: 0.1, size: 0.035, color: _color));
      _selected = _items.length - 1;
      _tool = _Tool.move;
    });
  }

  Future<void> _addSignature() async {
    final strokes = await Navigator.of(context).push<List<double>>(MaterialPageRoute(builder: (_) => const SignatureScreen()));
    if (strokes == null || strokes.isEmpty) return;
    _push();
    setState(() {
      _items.add(AnnotItem(type: 'sig', points: strokes, x: 0.55, y: 0.75, size: 0.35, color: 0xFF0D1B6E));
      _selected = _items.length - 1;
      _tool = _Tool.move;
    });
  }

  int? _hit(Offset n) {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].bounds(_aspect).inflate(0.02).contains(n)) return i;
    }
    return null;
  }

  Future<void> _save() async {
    final page = widget.page;
    final repo = ref.read(repositoryProvider);
    await runBusy<void>(context, 'Saving annotations…', (_) async {
      final json = jsonEncode(_items.map((e) => e.toJson()).toList());
      String? overlay;
      if (_items.isNotEmpty) {
        final long = math.min(2400, math.max(page.width, page.height));
        final w = page.width >= page.height ? long : (long * _aspect).round();
        final h = page.width >= page.height ? (long / _aspect).round() : long;
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        AnnotPainter(_items).paint(canvas, Size(w.toDouble(), h.toDouble()));
        final img = await rec.endRecording().toImage(w, h);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        if (data != null) {
          overlay = p.join(AppStorage.instance.cache.path, 'overlay_${newId()}.png');
          await File(overlay).writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
      }
      await repo.setPageAnnotations(page, annotJson: json, overlayAbsPath: overlay);
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = [0xFF1E3A8A, 0xFF000000, 0xFFD32F2F, 0xFF2E7D32, 0xFFF9A825];
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirm(context, 'Discard changes?', 'Your annotations have not been saved.', ok: 'Discard', destructive: true);
        if (leave && context.mounted) {
          _dirty = false;
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Annotate'),
          actions: [
            IconButton(
              tooltip: 'Undo',
              onPressed: _undo.isEmpty ? null : () => setState(() => _items = _undo.removeLast()),
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: _selected == null
                  ? null
                  : () {
                      _push();
                      setState(() {
                        _items.removeAt(_selected!);
                        _selected = null;
                      });
                    },
              icon: const Icon(Icons.delete_outline),
            ),
            TextButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspect,
                child: LayoutBuilder(builder: (ctx, box) {
                  Offset norm(Offset l) => Offset(l.dx / box.maxWidth, l.dy / box.maxHeight);
                  return GestureDetector(
                    onPanStart: (d) {
                      final n = norm(d.localPosition);
                      if (_tool == _Tool.pen || _tool == _Tool.highlight) {
                        _push();
                        setState(() => _current = [n.dx, n.dy]);
                      } else if (_tool == _Tool.move) {
                        final hit = _hit(n);
                        if (hit != null) _push();
                        setState(() {
                          _selected = hit;
                          _lastDrag = n;
                        });
                      }
                    },
                    onPanUpdate: (d) {
                      final n = norm(d.localPosition);
                      if (_current != null) {
                        setState(() => _current!.addAll([n.dx, n.dy]));
                      } else if (_tool == _Tool.move && _selected != null && _lastDrag != null) {
                        final dx = n.dx - _lastDrag!.dx, dy = n.dy - _lastDrag!.dy;
                        setState(() {
                          _items[_selected!] = _items[_selected!].moved(dx, dy);
                          _lastDrag = n;
                        });
                      }
                    },
                    onPanEnd: (_) {
                      final c = _current;
                      if (c != null && c.length >= 4) {
                        setState(() {
                          _items.add(AnnotItem(
                            type: _tool == _Tool.highlight ? 'highlight' : 'ink',
                            points: c,
                            color: _color,
                            width: _tool == _Tool.highlight ? _width * 5 : _width,
                          ));
                        });
                      }
                      setState(() {
                        _current = null;
                        _lastDrag = null;
                      });
                    },
                    onTapUp: (d) {
                      if (_tool == _Tool.move) setState(() => _selected = _hit(norm(d.localPosition)));
                    },
                    child: Stack(fit: StackFit.expand, children: [
                      StoredImage(widget.page.displayPath, fit: BoxFit.fill),
                      CustomPaint(
                        painter: AnnotPainter([
                          ..._items,
                          if (_current != null)
                            AnnotItem(
                              type: _tool == _Tool.highlight ? 'highlight' : 'ink',
                              points: _current!,
                              color: _color,
                              width: _tool == _Tool.highlight ? _width * 5 : _width,
                            ),
                        ], selected: _tool == _Tool.move ? _selected : null),
                      ),
                    ]),
                  );
                }),
              ),
            ),
          ),
          if (_tool == _Tool.move && _selected != null && (_items[_selected!].type == 'text' || _items[_selected!].type == 'sig'))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LabeledSlider(
                label: 'Size',
                value: _items[_selected!].size,
                min: 0.01,
                max: _items[_selected!].type == 'sig' ? 0.8 : 0.12,
                format: (v) => '${(v * 100).round()}',
                onChanged: (v) => setState(() => _items[_selected!] = _items[_selected!].resized(v)),
              ),
            ),
          if (_tool == _Tool.pen || _tool == _Tool.highlight || _tool == _Tool.text)
            SizedBox(
              height: 48,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final c in colors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(color: _color == c ? Theme.of(context).colorScheme.primary : Colors.white, width: 3),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: Slider(value: _width, min: 0.002, max: 0.012, onChanged: (v) => setState(() => _width = v)),
                ),
              ]),
            ),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tool.index,
          onDestinationSelected: (i) {
            final t = _Tool.values[i];
            if (t == _Tool.text) {
              _addText();
              return;
            }
            if (t == _Tool.sign) {
              _addSignature();
              return;
            }
            setState(() {
              _tool = t;
              _selected = null;
            });
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.edit), label: 'Pen'),
            NavigationDestination(icon: Icon(Icons.highlight), label: 'Highlight'),
            NavigationDestination(icon: Icon(Icons.text_fields), label: 'Text'),
            NavigationDestination(icon: Icon(Icons.open_with), label: 'Move'),
            NavigationDestination(icon: Icon(Icons.draw), label: 'Sign'),
          ],
        ),
      ),
    );
  }
}

/// Signature pad. Saved signatures are kept privately for reuse.
/// Returns strokes normalised to a 2.5:1 box, separated by NaN pairs.
class SignatureScreen extends StatefulWidget {
  const SignatureScreen({super.key});

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  final List<double> _pts = [];
  List<File> _saved = [];

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Directory get _dir => Directory(AppStorage.instance.abs('signatures'));

  Future<void> _loadSaved() async {
    try {
      final files = (await _dir.list().toList()).whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      setState(() => _saved = files);
    } catch (_) {}
  }

  List<double> _read(File f) {
    try {
      return (jsonDecode(f.readAsStringSync()) as List).map((e) => e == null ? double.nan : (e as num).toDouble()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _use({bool save = false}) async {
    if (_pts.isEmpty) return;
    if (save) {
      await _dir.create(recursive: true);
      await File(p.join(_dir.path, '${newId()}.json')).writeAsString(jsonEncode(_pts.map((e) => e.isNaN ? null : e).toList()));
    }
    if (mounted) Navigator.pop(context, List<double>.from(_pts));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signature'), actions: [
        TextButton(onPressed: () => setState(_pts.clear), child: const Text('Clear')),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: AspectRatio(
            aspectRatio: 2.5,
            child: LayoutBuilder(builder: (ctx, box) {
              Offset n(Offset o) => Offset((o.dx / box.maxWidth).clamp(0.0, 1.0).toDouble(), (o.dy / box.maxHeight).clamp(0.0, 1.0).toDouble());
              return GestureDetector(
                onPanStart: (d) => setState(() {
                  if (_pts.isNotEmpty) _pts.addAll([double.nan, double.nan]);
                  final o = n(d.localPosition);
                  _pts.addAll([o.dx, o.dy]);
                }),
                onPanUpdate: (d) => setState(() {
                  final o = n(d.localPosition);
                  _pts.addAll([o.dx, o.dy]);
                }),
                child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey)),
                  child: CustomPaint(
                    painter: AnnotPainter([AnnotItem(type: 'sig', points: _pts, x: 0, y: 0, size: 1, color: 0xFF0D1B6E)]),
                    size: Size.infinite,
                  ),
                ),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: _pts.isEmpty ? null : () => _use(), child: const Text('Use once'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton(onPressed: _pts.isEmpty ? null : () => _use(save: true), child: const Text('Save & use'))),
          ]),
        ),
        if (_saved.isNotEmpty) const SectionHeader('Saved signatures'),
        Expanded(
          child: ListView(children: [
            for (final f in _saved)
              ListTile(
                title: SizedBox(
                  height: 60,
                  child: CustomPaint(painter: AnnotPainter([AnnotItem(type: 'sig', points: _read(f), size: 0.5, color: 0xFF0D1B6E)])),
                ),
                onTap: () => Navigator.pop(context, _read(f)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete signature',
                  onPressed: () async {
                    await f.delete();
                    _loadSaved();
                  },
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}
