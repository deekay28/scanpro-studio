import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../../core/ids.dart';
import '../../core/import_service.dart';
import '../../core/models.dart';
import '../../core/naming.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../core/units.dart';
import '../../shared/widgets.dart';
import '../pdf/export_actions.dart';
import '../pdf/pdf_library.dart';
import '../pdf_editor/editor/image_library.dart';
import '../pdf/pdf_viewer_screen.dart';
import 'calibration_screen.dart';
import 'frame_editor.dart';
import 'mask_refine_screen.dart';
import 'photo_presets.dart';
import 'portrait_render.dart';
import 'preset_editor_screen.dart';
import 'print_layout.dart';
import 'sheet_preview.dart';
import 'sheet_renderer.dart';

/// Passport & ID Photo Studio:
/// 1 Photo → 2 Frame (face detection + guides) → 3 Background & tone →
/// 4 Print sheet (physical layout optimiser) → 5 Export (PDF/PNG/JPEG).
class PassportStudioScreen extends ConsumerStatefulWidget {
  final bool embedded;
  const PassportStudioScreen({super.key, this.embedded = false});

  @override
  ConsumerState<PassportStudioScreen> createState() => _PassportStudioScreenState();
}

class _PassportStudioScreenState extends ConsumerState<PassportStudioScreen> {
  int _step = 0;
  List<PhotoPreset> _presets = builtInPresets;
  PhotoPreset _preset = builtInPresets.first;

  // Source
  String? _src;
  int _srcW = 0, _srcH = 0;
  PortraitCrop? _crop;
  String? _faceNote;

  // Background
  String? _cropPath;
  Uint8List? _mask;
  List<MaskStroke> _strokes = [];
  bool _replaceBg = true;
  int _bg = 0xFFFFFFFF;
  PortraitAdjust _adjust = const PortraitAdjust();
  String? _finalPath;
  int _finalRev = 0;
  Timer? _composeDebounce;
  bool _composing = false;
  String? _segNote;

  // Sheet
  SheetSpec _spec = const SheetSpec(paper: PaperSizes.a4, photoWmm: 35, photoHmm: 45, copies: 8);
  bool _manual = false;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  @override
  void dispose() {
    _composeDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    try {
      final list = await PresetStore(ref.read(databaseProvider).db).load();
      if (!mounted) return;
      setState(() {
        _presets = list;
        _preset = list.firstWhere((p) => p.id == _preset.id, orElse: () => list.first);
        _bg = _preset.backgroundArgb;
        _spec = _spec.copyWith(photoWmm: _preset.widthMm, photoHmm: _preset.heightMm);
      });
    } catch (_) {}
  }

  void _selectPreset(PhotoPreset p) {
    setState(() {
      _preset = p;
      _bg = p.backgroundArgb;
      _spec = _spec.copyWith(photoWmm: p.widthMm, photoHmm: p.heightMm);
      _cropPath = null;
      _finalPath = null;
    });
    if (_src != null) _autoFrame();
  }

  // ---------------------------------------------------------------- step 1
  Future<void> _pick({bool camera = false, bool front = false}) async {
    final p = camera ? await ImportService.captureWithSystemCamera(front: front) : (await ImportService.pickImages(multiple: false)).firstOrNull;
    if (p == null || !mounted) return;
    final ok = await runBusy(context, 'Preparing photo…', (ctl) async {
      final norm = await ImportService.normalize(p);
      final out = AppStorage.instance.tempPath('portrait_src.jpg');
      final (w, h) = await preparePortraitSource(norm.path, out);
      _src = out;
      _srcW = w;
      _srcH = h;
      ctl.update('Detecting face…');
      await _autoFrame(silent: true);
      return true;
    });
    if (ok == true && mounted) {
      setState(() {
        _step = 1;
        _cropPath = null;
        _finalPath = null;
        _mask = null;
        _strokes = [];
      });
    }
  }

  Future<void> _autoFrame({bool silent = false}) async {
    final src = _src;
    if (src == null) return;
    final detector = FaceDetector(options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate));
    try {
      final faces = await detector.processImage(InputImage.fromFilePath(src));
      if (faces.isEmpty) {
        _crop = PortraitCrop(_srcW / 2, _srcH / 2, math.min(_srcH * 0.8, _srcW * _preset.aspect * 0.9), 0);
        _faceNote = 'No face detected. Position the head inside the guides manually.';
      } else {
        faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height));
        final f = faces.first.boundingBox;
        _crop = suggestCrop(
          faceLeft: f.left,
          faceTop: f.top,
          faceWidth: f.width,
          faceHeight: f.height,
          aspect: _preset.aspect,
          headFraction: (_preset.headMin + _preset.headMax) / 2,
          topMargin: _preset.topMargin,
        );
        final roll = faces.first.headEulerAngleZ ?? 0;
        final yaw = faces.first.headEulerAngleY ?? 0;
        final notes = <String>[];
        if (faces.length > 1) notes.add('${faces.length} faces found; the largest was used.');
        if (roll.abs() > 4) notes.add('Head is tilted ${roll.abs().round()}° — use Straighten or retake.');
        if (yaw.abs() > 10) notes.add('Face is turned to the side — most offices require a straight-on pose.');
        _faceNote = notes.isEmpty ? 'Face detected and framed automatically. Fine-tune with pinch and drag.' : notes.join(' ');
      }
    } catch (e) {
      _crop ??= PortraitCrop(_srcW / 2, _srcH / 2, _srcH * 0.7, 0);
      _faceNote = 'Face detection unavailable ($e). Frame manually.';
    } finally {
      await detector.close();
    }
    if (mounted && !silent) setState(() {});
  }

  double get _effectiveDpi => _crop == null ? 0 : PrintLayoutEngine.effectiveDpi(_crop!.cropH.round(), _preset.heightMm);

  // ---------------------------------------------------------------- step 2
  Future<void> _confirmFrame() async {
    final src = _src, crop = _crop;
    if (src == null || crop == null) return;
    final ok = await runBusy(context, 'Cropping and finding the subject…', (ctl) async {
      final out = AppStorage.instance.tempPath('portrait_crop.jpg');
      await renderCropFile(src, crop, _preset.pixelWidth, _preset.pixelHeight, out);
      _cropPath = out;
      _strokes = [];
      _mask = null;
      _segNote = null;
      final seg = SelfieSegmenter(mode: SegmenterMode.single, enableRawSizeMask: false);
      try {
        final m = await seg.processImage(InputImage.fromFilePath(out));
        if (m != null) {
          _mask = confidencesToMask(m.confidences, m.width, m.height, _preset.pixelWidth, _preset.pixelHeight);
        } else {
          _segNote = 'Could not separate the person from the background. You can still keep the original background.';
        }
      } catch (e) {
        _segNote = 'Background detection unavailable on this device ($e).';
      } finally {
        await seg.close();
      }
      if (_mask == null) _replaceBg = false;
      await _compose();
      return true;
    });
    if (ok == true && mounted) setState(() => _step = 2);
  }

  Future<void> _compose() async {
    final crop = _cropPath;
    if (crop == null) return;
    _composing = true;
    try {
      final out = AppStorage.instance.tempPath('portrait_final.jpg');
      await composePortrait(ComposeInput(
        cropPath: crop,
        mask: _mask,
        strokes: _strokes.map((e) => e.toJson()).toList(),
        bgArgb: _bg,
        replaceBackground: _replaceBg && _mask != null,
        adjust: _adjust,
        outPath: out,
      ));
      final old = _finalPath;
      _finalPath = out;
      _finalRev++;
      if (old != null && old != out) {
        try {
          File(old).deleteSync();
        } catch (_) {}
      }
    } finally {
      _composing = false;
    }
    if (mounted) setState(() {});
  }

  void _recompose() {
    _composeDebounce?.cancel();
    _composeDebounce = Timer(const Duration(milliseconds: 250), _compose);
    setState(() {});
  }

  Future<void> _refine() async {
    final crop = _cropPath, mask = _mask;
    if (crop == null || mask == null) return;
    final r = await Navigator.of(context).push<List<MaskStroke>>(MaterialPageRoute(
      builder: (_) => MaskRefineScreen(imagePath: crop, width: _preset.pixelWidth, height: _preset.pixelHeight, mask: mask, strokes: _strokes),
    ));
    if (r == null) return;
    _strokes = r;
    await _compose();
  }

  // ---------------------------------------------------------------- export
  SheetLayout get _layout => PrintLayoutEngine.compute(_manual ? _spec : _spec.copyWith(clearManual: true));

  String get _title => '${_preset.name} ×${_layout.placed} ${formatDate(DateTime.now())}';

  Future<Uint8List> _photoBytes() async => File(_finalPath!).readAsBytes();

  Future<void> _exportPdf() async {
    final layout = _layout;
    if (layout.placed == 0) {
      showSnack(context, 'Nothing fits on the sheet with these settings.');
      return;
    }
    final bytes = SheetRenderer.buildPdf(_spec, layout, await _photoBytes(), title: _title, photoLabel: _preset.name);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(bytes: bytes, title: _title, printWarning: printScaleWarning, offerSaveToLibrary: false),
    ));
  }

  Future<void> _saveToLibrary() async {
    final layout = _layout;
    final repo = ref.read(repositoryProvider);
    final photo = await _photoBytes();
    if (!mounted) return;
    final d = await runBusy(context, 'Saving…', (_) async {
      final bytes = SheetRenderer.buildPdf(_spec, layout, photo, title: _title, photoLabel: _preset.name);
      return PdfLibrary.saveToLibrary(repo, bytes, _title, kind: DocKind.photoSheet);
    });
    if (d != null && mounted) showSnack(context, 'Sheet saved to Documents › Photo sheets');
  }

  Future<void> _exportRaster({required bool png, required int dpi, bool share = true}) async {
    final layout = _layout;
    final bytes = await runBusy(context, 'Rendering ${png ? 'PNG' : 'JPEG'} at $dpi dpi…',
        (_) => SheetRenderer.buildRaster(_spec, layout, _finalPath!, dpi: dpi, png: png));
    if (bytes == null) return;
    final name = Naming.withExtension('${_title}_${dpi}dpi', png ? 'png' : 'jpg');
    if (share) {
      await ExportActions.shareBytes(bytes, name, mime: png ? 'image/png' : 'image/jpeg');
    } else {
      final r = await ExportActions.saveBytes(bytes, name);
      if (r != null && mounted) showSnack(context, 'Saved $name');
    }
  }

  /// Keeps the finished photo in the app so it can be inserted into a PDF
  /// form with the PDF editor (Insert Image → Saved in ScanPro).
  Future<void> _keepForEditor() async {
    if (_finalPath == null) return;
    await ImageLibrary.images.save(await _photoBytes(), ext: 'jpg', label: _preset.name);
    if (mounted) showSnack(context, 'Photo kept. In the PDF editor use Insert Image → Saved in ScanPro.');
  }

  Future<void> _exportSingle() async {
    final path = _finalPath;
    if (path == null) return;
    final bytes = withJpegDpi(await File(path).readAsBytes(), _preset.dpi);
    await ExportActions.shareBytes(bytes, Naming.withExtension('${_preset.name} photo', 'jpg'), mime: 'image/jpeg');
  }

  void _reset() => setState(() {
        _step = 0;
        _src = null;
        _crop = null;
        _cropPath = null;
        _finalPath = null;
        _mask = null;
      });

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final steps = ['Photo', 'Frame', 'Background', 'Sheet', 'Export'];
    final canGo = [true, _src != null, _cropPath != null, _finalPath != null, _finalPath != null];
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('ID Photo Studio'),
        actions: [
          if (_src != null) IconButton(onPressed: _reset, icon: const Icon(Icons.restart_alt), tooltip: 'Start over'),
          IconButton(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PresetEditorScreen()));
              await _loadPresets();
            },
            icon: const Icon(Icons.tune),
            tooltip: 'Edit presets',
          ),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: steps.length,
            separatorBuilder: (_, __) => const Icon(Icons.chevron_right, size: 18),
            itemBuilder: (ctx, i) => ChoiceChip(
              label: Text('${i + 1}. ${steps[i]}'),
              selected: _step == i,
              onSelected: canGo[i]
                  ? (_) {
                      if (i == 2 && _cropPath == null) return;
                      setState(() => _step = i);
                    }
                  : null,
            ),
          ),
        ),
        Expanded(
          child: switch (_step) {
            0 => _photoStep(),
            1 => _frameStep(),
            2 => _bgStep(),
            3 => _sheetStep(),
            _ => _exportStep(),
          },
        ),
      ]),
    );
  }

  Widget _presetPicker() => DropdownButton<String>(
        isExpanded: true,
        value: _preset.id,
        items: [
          for (final p in _presets) DropdownMenuItem(value: p.id, child: Text('${p.name} · ${p.sizeLabel}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) {
          final p = _presets.where((e) => e.id == id).firstOrNull;
          if (p != null) _selectPreset(p);
        },
      );

  Widget _photoStep() {
    final t = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('1. Choose the photo size', style: t.textTheme.titleMedium),
      _presetPicker(),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_preset.sizeLabel} · ${_preset.pixelWidth}×${_preset.pixelHeight} px at ${_preset.dpi} dpi', style: t.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(_preset.notes, style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text('Requirements vary by country and office and change over time. Verify with the official source before printing.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      Text('2. Add a portrait', style: t.textTheme.titleMedium),
      const SizedBox(height: 8),
      FilledButton.icon(onPressed: () => _pick(camera: true), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Take photo (rear camera)')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: () => _pick(camera: true, front: true), icon: const Icon(Icons.camera_front_outlined), label: const Text('Selfie camera')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: () => _pick(), icon: const Icon(Icons.photo_library_outlined), label: const Text('Choose from gallery')),
      const SizedBox(height: 16),
      const Text(
        'Tips: face the camera straight on, neutral expression, even light without shadows, plain light wall behind. '
        'The app never reshapes or beautifies faces.',
        style: TextStyle(fontSize: 12),
      ),
    ]);
  }

  Widget _frameStep() {
    final src = _src, crop = _crop;
    if (src == null || crop == null) return const SizedBox();
    final dpi = _effectiveDpi;
    final low = dpi < 300;
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _presetPicker()),
      if (_faceNote != null)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_faceNote!, style: const TextStyle(fontSize: 12))),
      Expanded(
        child: FrameEditor(
          imagePath: src,
          imageWidth: _srcW,
          imageHeight: _srcH,
          preset: _preset,
          crop: crop,
          backgroundArgb: 0xFF9E9E9E,
          onChanged: (c) => setState(() => _crop = c),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          Row(children: [
            Icon(low ? Icons.warning_amber : Icons.check_circle, size: 16, color: low ? Colors.orange : Colors.green),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                low
                    ? 'Source resolution prints at only ${dpi.round()} dpi (300+ recommended). Use a sharper or closer photo.'
                    : 'Source resolution: ${dpi.round()} dpi at ${_preset.sizeLabel}.',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ]),
          LabeledSlider(
            label: 'Zoom',
            value: (_srcH / crop.cropH).clamp(0.5, 6.0).toDouble(),
            min: 0.5,
            max: 6,
            format: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => setState(() => _crop = crop.copyWith(cropH: _srcH / v)),
          ),
          LabeledSlider(
            label: 'Straighten',
            value: crop.angle,
            min: -15,
            max: 15,
            format: (v) => '${v.toStringAsFixed(1)}°',
            onChanged: (v) => setState(() => _crop = crop.copyWith(angle: v)),
          ),
          Row(children: [
            TextButton.icon(onPressed: _autoFrame, icon: const Icon(Icons.face_retouching_natural), label: const Text('Auto-frame')),
            const Spacer(),
            FilledButton.icon(onPressed: _confirmFrame, icon: const Icon(Icons.arrow_forward), label: const Text('Next')),
          ]),
        ]),
      ),
    ]);
  }

  Widget _bgStep() {
    final finalPath = _finalPath;
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Column(children: [
                const Text('Original crop', style: TextStyle(fontSize: 12)),
                Expanded(child: _cropPath == null ? const SizedBox() : Image.file(File(_cropPath!), fit: BoxFit.contain)),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(children: [
                Text(_composing ? 'Updating…' : 'Result', style: const TextStyle(fontSize: 12)),
                Expanded(
                  child: finalPath == null
                      ? const Center(child: CircularProgressIndicator())
                      : Image.file(File(finalPath), key: ValueKey(_finalRev), fit: BoxFit.contain, gaplessPlayback: true),
                ),
              ]),
            ),
          ]),
        ),
      ),
      SizedBox(
        height: 300,
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          if (_segNote != null) Text(_segNote!, style: const TextStyle(fontSize: 12, color: Colors.orange)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Replace background'),
            subtitle: const Text('Check hair, ears, glasses and collar edges carefully'),
            value: _replaceBg && _mask != null,
            onChanged: _mask == null
                ? null
                : (v) {
                    _replaceBg = v;
                    _recompose();
                  },
          ),
          if (_replaceBg && _mask != null) ...[
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (name, argb) in backgroundChoices)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: Color(argb), radius: 8),
                  label: Text(name),
                  selected: _bg == argb,
                  onSelected: (_) {
                    _bg = argb;
                    _recompose();
                  },
                ),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _refine, icon: const Icon(Icons.brush), label: Text('Refine edges${_strokes.isEmpty ? '' : ' (${_strokes.length})'}')),
            ),
          ],
          LabeledSlider(label: 'Brightness', value: _adjust.brightness, onChanged: (v) {
            _adjust = _adjust.copyWith(brightness: v);
            _recompose();
          }),
          LabeledSlider(label: 'Contrast', value: _adjust.contrast, onChanged: (v) {
            _adjust = _adjust.copyWith(contrast: v);
            _recompose();
          }),
          LabeledSlider(label: 'Saturation', value: _adjust.saturation, onChanged: (v) {
            _adjust = _adjust.copyWith(saturation: v);
            _recompose();
          }),
          LabeledSlider(label: 'Warmth', value: _adjust.warmth, onChanged: (v) {
            _adjust = _adjust.copyWith(warmth: v);
            _recompose();
          }),
          LabeledSlider(label: 'Sharpen', value: _adjust.sharpen, min: 0, onChanged: (v) {
            _adjust = _adjust.copyWith(sharpen: v);
            _recompose();
          }),
          LabeledSlider(label: 'Noise reduction', value: _adjust.denoise, min: 0, onChanged: (v) {
            _adjust = _adjust.copyWith(denoise: v);
            _recompose();
          }),
          Row(children: [
            TextButton(
              onPressed: () {
                _adjust = const PortraitAdjust();
                _recompose();
              },
              child: const Text('Reset tone'),
            ),
            const Spacer(),
            FilledButton.icon(onPressed: finalPath == null ? null : () => setState(() => _step = 3), icon: const Icon(Icons.arrow_forward), label: const Text('Next')),
          ]),
        ]),
      ),
    ]);
  }

  Widget _sheetStep() {
    final layout = _layout;
    final t = Theme.of(context);
    final copiesOptions = [2, 4, 6, 8, 10, 12];
    return Column(children: [
      Expanded(
        flex: 5,
        child: Padding(padding: const EdgeInsets.all(12), child: SheetPreview(layout: layout, spec: _spec, photoPath: _finalPath)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${layout.placed} photo(s) · ${layout.rows}×${layout.cols} grid · max ${layout.capacity} per sheet · '
            '${(layout.usageRatio * 100).round()}% of paper used (${(layout.unusedAreaMm2 / 100).round()} cm² unused)',
            style: t.textTheme.bodySmall,
          ),
          for (final w in layout.warnings) Text('⚠ $w', style: t.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800)),
        ]),
      ),
      Expanded(
        flex: 5,
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in PaperSizes.photoSheetSizes)
              ChoiceChip(label: Text(p.name), selected: _spec.paper.id == p.id, onSelected: (_) => setState(() => _spec = _spec.copyWith(paper: p))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Portrait'), icon: Icon(Icons.crop_portrait)),
                ButtonSegment(value: true, label: Text('Landscape'), icon: Icon(Icons.crop_landscape)),
              ],
              selected: {_spec.landscape},
              onSelectionChanged: (s) => setState(() => _spec = _spec.copyWith(landscape: s.first)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => _spec = _spec.copyWith(landscape: PrintLayoutEngine.bestLandscape(_spec))),
              child: const Text('Best fit'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Copies', style: t.textTheme.labelLarge),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final n in copiesOptions)
              ChoiceChip(label: Text('$n'), selected: _spec.copies == n && !_manual, onSelected: (_) => setState(() {
                    _manual = false;
                    _spec = _spec.copyWith(copies: n);
                  })),
            ChoiceChip(
              label: const Text('Fill sheet'),
              selected: _spec.copies == null && !_manual,
              onSelected: (_) => setState(() {
                _manual = false;
                _spec = _spec.copyWith(clearCopies: true);
              }),
            ),
            ActionChip(
              label: const Text('Custom…'),
              onPressed: () async {
                final v = await promptText(context, 'Number of copies', keyboard: TextInputType.number, initial: '${_spec.copies ?? layout.capacity}');
                final n = int.tryParse(v ?? '');
                if (n != null && n > 0) {
                  setState(() {
                    _manual = false;
                    _spec = _spec.copyWith(copies: n);
                  });
                }
              },
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Manual grid (rows × columns)'),
            value: _manual,
            onChanged: (v) => setState(() {
              _manual = v;
              if (v) _spec = _spec.copyWith(rows: layout.rows == 0 ? 1 : layout.rows, cols: layout.cols == 0 ? 1 : layout.cols);
            }),
          ),
          if (_manual)
            Row(children: [
              _stepper('Rows', _spec.rows ?? 1, (v) => setState(() => _spec = _spec.copyWith(rows: v, copies: v * (_spec.cols ?? 1)))),
              const SizedBox(width: 16),
              _stepper('Columns', _spec.cols ?? 1, (v) => setState(() => _spec = _spec.copyWith(cols: v, copies: v * (_spec.rows ?? 1)))),
            ]),
          LabeledSlider(
            label: 'Margins',
            value: _spec.marginMm,
            min: 0,
            max: 20,
            format: (v) => '${v.toStringAsFixed(1)} mm',
            onChanged: (v) => setState(() => _spec = _spec.copyWith(marginMm: (v * 2).round() / 2)),
          ),
          LabeledSlider(
            label: 'Gap',
            value: _spec.gapMm,
            min: 0,
            max: 10,
            format: (v) => '${v.toStringAsFixed(1)} mm',
            onChanged: (v) => setState(() => _spec = _spec.copyWith(gapMm: (v * 2).round() / 2)),
          ),
          LabeledSlider(
            label: 'White border',
            value: _spec.borderMm,
            min: 0,
            max: 3,
            format: (v) => '${v.toStringAsFixed(1)} mm',
            onChanged: (v) => setState(() => _spec = _spec.copyWith(borderMm: (v * 2).round() / 2)),
          ),
          if (_spec.borderMm > 0)
            const Text('Note: a border reduces the visible photo inside the cell; the cell stays at the exact photo size.', style: TextStyle(fontSize: 11)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Cut lines'), value: _spec.cutLines, onChanged: (v) => setState(() => _spec = _spec.copyWith(cutLines: v))),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Crop marks'), value: _spec.cropMarks, onChanged: (v) => setState(() => _spec = _spec.copyWith(cropMarks: v))),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Size label & 30 mm scale bar'),
            subtitle: const Text('Printed in the bottom margin when there is room'),
            value: _spec.labels,
            onChanged: (v) => setState(() => _spec = _spec.copyWith(labels: v)),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: layout.placed == 0 ? null : () => setState(() => _step = 4),
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next'),
            ),
          ),
          const SizedBox(height: 16),
        ]),
      ),
    ]);
  }

  Widget _stepper(String label, int value, ValueChanged<int> onChanged) => Row(children: [
        Text(label),
        IconButton(onPressed: value > 1 ? () => onChanged(value - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
        Text('$value', style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(onPressed: value < 20 ? () => onChanged(value + 1) : null, icon: const Icon(Icons.add_circle_outline)),
      ]);

  Widget _exportStep() {
    final layout = _layout;
    final t = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: _finalPath == null ? null : Image.file(File(_finalPath!), key: ValueKey(_finalRev), width: 44),
          title: Text('${layout.placed} × ${_preset.sizeLabel} on ${_spec.paper.oriented(_spec.landscape).name}'),
          subtitle: Text('${_spec.paper.oriented(_spec.landscape).widthMm.toStringAsFixed(1)} × ${_spec.paper.oriented(_spec.landscape).heightMm.toStringAsFixed(1)} mm paper · '
              'photo ${_preset.pixelWidth}×${_preset.pixelHeight} px (${_preset.dpi} dpi)'),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _exportPdf, icon: const Icon(Icons.picture_as_pdf), label: const Text('Print-ready PDF (preview, print, share)')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _saveToLibrary, icon: const Icon(Icons.library_add_outlined), label: const Text('Save sheet in app')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _keepForEditor, icon: const Icon(Icons.collections_bookmark_outlined), label: const Text('Keep photo for PDF editor')),
      const SizedBox(height: 16),
      Text('High-resolution image (DPI embedded)', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => _exportRaster(png: true, dpi: 300), child: const Text('PNG 300 dpi')),
        OutlinedButton(onPressed: () => _exportRaster(png: true, dpi: 600), child: const Text('PNG 600 dpi')),
        OutlinedButton(onPressed: () => _exportRaster(png: false, dpi: 300), child: const Text('JPEG 300 dpi')),
        OutlinedButton(onPressed: () => _exportRaster(png: false, dpi: 300, share: false), child: const Text('Save JPEG to device')),
      ]),
      const SizedBox(height: 8),
      TextButton.icon(onPressed: _exportSingle, icon: const Icon(Icons.portrait), label: const Text('Share single photo (for online applications)')),
      const Divider(height: 32),
      Card(
        color: t.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Print at actual size', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'The PDF is laid out in millimetres. In the print dialog choose the matching paper and 100% / "Actual size". '
              '"Fit to page" will shrink the photos. Printer margins and drivers can still cause small deviations.',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CalibrationScreen())), child: const Text('Print a calibration page')),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Text('All processing happens on this device.', style: t.textTheme.bodySmall),
    ]);
  }
}

