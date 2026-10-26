import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/import_service.dart';
import '../../../core/storage.dart';
import '../../../shared/widgets.dart';
import 'image_library.dart';

/// What the Sign tool returns: a transparent PNG and optional details to
/// place beside it.
class SignatureChoice {
  final Uint8List png;
  final String name;
  final String designation;
  final bool addDate;
  const SignatureChoice(this.png, {this.name = '', this.designation = '', this.addDate = false});
}

/// Saved signatures, drawing and importing. Signatures are images of a
/// handwritten signature, kept only on this device.
class SignatureScreen extends StatefulWidget {
  const SignatureScreen({super.key});

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  List<File> _saved = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ImageLibrary.migrateStrokeSignatures();
    final l = await ImageLibrary.signatures.list();
    if (mounted) {
      setState(() {
        _saved = l;
        _loading = false;
      });
    }
  }

  Future<void> _use(Uint8List png) async {
    final details = await showDialog<SignatureChoice>(context: context, builder: (_) => _DetailsDialog(png: png));
    if (details != null && mounted) Navigator.pop(context, details);
  }

  Future<void> _draw() async {
    final png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => const _DrawSignatureScreen()));
    if (png == null || !mounted) return;
    await _offerSave(png);
  }

  Future<void> _import() async {
    final paths = await ImportService.pickImages(multiple: false);
    if (paths.isEmpty || !mounted) return;
    final bytes = await File(paths.first).readAsBytes();
    if (!mounted) return;
    final png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => _CleanupScreen(source: bytes)));
    if (png == null || !mounted) return;
    await _offerSave(png);
  }

  Future<void> _offerSave(Uint8List png) async {
    final save = await confirm(context, 'Save this signature?', 'Saved signatures stay private on this device and can be deleted at any time.', ok: 'Save');
    if (save) {
      await ImageLibrary.signatures.save(png, label: 'signature');
      await _load();
    }
    if (mounted) await _use(png);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sign')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: t.colorScheme.secondaryContainer,
          child: const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Handwritten signature image'),
            subtitle: Text('This places a picture of your signature on the page. It is not a cryptographic digital signature and does not prove who signed or that the document is unchanged.'),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _draw, icon: const Icon(Icons.draw_outlined), label: const Text('Draw'))),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.image_outlined), label: const Text('Import image'))),
        ]),
        const SizedBox(height: 16),
        const SectionHeader('Saved signatures'),
        if (_loading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
        if (!_loading && _saved.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No saved signatures yet. Draw or import one; you can choose to keep it for next time.')),
        for (final f in _saved)
          Card(
            child: InkWell(
              onTap: () async => _use(await f.readAsBytes()),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(
                    child: Container(
                      height: 72,
                      color: Colors.white,
                      padding: const EdgeInsets.all(6),
                      child: Image.file(f, fit: BoxFit.contain),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete signature',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirm(context, 'Delete this signature?', 'It is removed from this device.', ok: 'Delete', destructive: true)) {
                        await ImageLibrary.signatures.delete(f);
                        await _load();
                      }
                    },
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _DetailsDialog extends StatefulWidget {
  final Uint8List png;
  const _DetailsDialog({required this.png});
  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  final _name = TextEditingController();
  final _role = TextEditingController();
  bool _date = false;

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add details?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(height: 70, color: Colors.white, child: Image.memory(widget.png, fit: BoxFit.contain)),
          const SizedBox(height: 8),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
          TextField(controller: _role, decoration: const InputDecoration(labelText: 'Designation (optional)')),
          CheckboxListTile(contentPadding: EdgeInsets.zero, value: _date, onChanged: (v) => setState(() => _date = v ?? false), title: const Text('Add today\'s date')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, SignatureChoice(widget.png, name: _name.text.trim(), designation: _role.text.trim(), addDate: _date)),
          child: const Text('Place on page'),
        ),
      ],
    );
  }
}

class _DrawSignatureScreen extends StatefulWidget {
  const _DrawSignatureScreen();
  @override
  State<_DrawSignatureScreen> createState() => _DrawSignatureScreenState();
}

class _DrawSignatureScreenState extends State<_DrawSignatureScreen> {
  final List<List<Offset>> _strokes = [];
  Color _color = const Color(0xFF0D1B6E);
  double _width = 4;

  Future<void> _done() async {
    final png = await renderStrokesPng(_strokes, color: _color, width: _width, scale: 3);
    if (png != null && mounted) Navigator.pop(context, png);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Draw signature'), actions: [
        IconButton(onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast), icon: const Icon(Icons.undo), tooltip: 'Undo stroke'),
        TextButton(onPressed: () => setState(_strokes.clear), child: const Text('Clear')),
      ]),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
              onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey)),
                child: CustomPaint(painter: _StrokePainter(_strokes, _color, _width), size: Size.infinite),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final c in const [Color(0xFF0D1B6E), Color(0xFF000000), Color(0xFF1565C0)])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(radius: 14, backgroundColor: c, child: _color == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                ),
              ),
            Expanded(child: Slider(min: 2, max: 9, value: _width, onChanged: (v) => setState(() => _width = v), label: 'Thickness')),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: FilledButton(onPressed: _strokes.isEmpty ? null : _done, child: const Text('Done'))),
          ),
        ),
      ]),
    );
  }
}

class _StrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  final double width;
  _StrokePainter(this.strokes, this.color, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(16, size.height * 0.72), Offset(size.width - 16, size.height * 0.72), Paint()..color = Colors.black12);
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.length < 2) {
        if (s.isNotEmpty) canvas.drawCircle(s.first, width / 2, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final o in s.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}

/// Removes the paper background of an imported signature or seal photo.
class _CleanupScreen extends StatefulWidget {
  final Uint8List source;
  const _CleanupScreen({required this.source});
  @override
  State<_CleanupScreen> createState() => _CleanupScreenState();
}

class _CleanupScreenState extends State<_CleanupScreen> {
  double _level = 0.25;
  bool _recolor = false;
  Uint8List? _result;
  String? _error;
  int _job = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final job = ++_job;
    try {
      final r = await cleanSignatureImage(widget.source, threshold: _level, recolor: _recolor);
      if (job == _job && mounted) {
        setState(() {
          _result = r;
          _error = null;
        });
      }
    } catch (e) {
      if (job == _job && mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Clean up image')),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CustomPaint(
              painter: _CheckerPainter(),
              child: Center(
                child: _error != null
                    ? Text(_error!)
                    : r == null
                        ? const CircularProgressIndicator()
                        : Image.memory(r, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
          ),
        ),
        LabeledSlider(
          label: 'Background removal',
          value: _level,
          min: 0.05,
          max: 0.6,
          onChanged: (v) => setState(() => _level = v),
          onChangeEnd: (_) => _run(),
        ),
        SwitchListTile(
          title: const Text('Make ink dark blue'),
          value: _recolor,
          onChanged: (v) {
            setState(() => _recolor = v);
            _run();
          },
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: FilledButton(onPressed: r == null ? null : () => Navigator.pop(context, r), child: const Text('Use'))),
          ),
        ),
      ]),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 12.0;
    final a = Paint()..color = const Color(0xFFE0E0E0);
    final b = Paint()..color = Colors.white;
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), ((x + y) / s).round().isEven ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
