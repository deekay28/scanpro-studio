import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import '../ocr/ocr_service.dart';
import 'crop_screen.dart';

enum _Compare { off, original, sideBySide }

/// Non-destructive page editor. Every change is a recipe applied to the
/// preserved original; "Revert all" returns to the untouched capture.
class PageEditorScreen extends ConsumerStatefulWidget {
  final DocPage page;
  const PageEditorScreen({super.key, required this.page});

  @override
  ConsumerState<PageEditorScreen> createState() => _PageEditorScreenState();
}

class _PageEditorScreenState extends ConsumerState<PageEditorScreen> {
  late PageEdit _edit = widget.page.edit;
  String? _src; // downscaled original for previews
  String? _thumbSrc; // tiny source for filter thumbnails
  Uint8List? _preview;
  final Map<FilterPreset, Uint8List> _thumbs = {};
  Timer? _debounce;
  int _renderId = 0;
  int _tab = 0;
  _Compare _compare = _Compare.off;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  String get _originalAbs => AppStorage.instance.abs(widget.page.originalPath);

  Future<void> _prepare() async {
    try {
      final s = AppStorage.instance;
      final src = s.tempPath('edit_src.jpg');
      await makePreviewSource(_originalAbs, src, maxDim: 1400);
      final small = s.tempPath('edit_thumb.jpg');
      await makePreviewSource(_originalAbs, small, maxDim: 260);
      if (!mounted) return;
      setState(() {
        _src = src;
        _thumbSrc = small;
      });
      _render();
      _renderThumbs();
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _renderThumbs() async {
    final src = _thumbSrc;
    if (src == null) return;
    for (final p in FilterPreset.values) {
      try {
        final e = PageEdit(corners: _edit.corners, rotation: _edit.rotation, preset: p);
        final b = await renderPreview(src, e.toJson(), maxDim: 260);
        if (!mounted) return;
        setState(() => _thumbs[p] = b);
      } catch (_) {}
    }
  }

  void _set(PageEdit e, {bool immediate = false}) {
    setState(() => _edit = e);
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 250), _render);
  }

  Future<void> _render() async {
    final src = _src;
    if (src == null) return;
    final id = ++_renderId;
    try {
      final b = await renderPreview(src, _edit.toJson(), maxDim: 1400);
      if (!mounted || id != _renderId) return;
      setState(() => _preview = b);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _crop() async {
    final r = await Navigator.of(context).push<CropResult>(MaterialPageRoute(
      builder: (_) => CropScreen(imagePath: _originalAbs, initialCorners: _edit.corners, rotation: _edit.rotation),
    ));
    if (r == null) return;
    _set(r.corners == null ? _edit.copyWith(clearCorners: true, rotation: r.rotation) : _edit.copyWith(corners: r.corners, rotation: r.rotation),
        immediate: true);
    _thumbs.clear();
    _renderThumbs();
  }

  Future<void> _autoDeskew() async {
    final src = _src;
    if (src == null) return;
    setState(() => _busy = true);
    try {
      final base = _edit.copyWith(fineAngle: 0, preset: FilterPreset.grayscale).resetAdjustments();
      final bytes = await renderPreview(src, base.toJson(), maxDim: 900);
      final tmp = AppStorage.instance.tempPath('deskew.jpg');
      await File(tmp).writeAsBytes(bytes);
      final angle = await estimateSkewForFile(tmp);
      if (!mounted) return;
      _set(_edit.copyWith(fineAngle: angle), immediate: true);
      showSnack(context, angle == 0 ? 'Page already looks straight' : 'Straightened by ${angle.toStringAsFixed(1)}°');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks the 90° rotation in which OCR finds the most text.
  Future<void> _autoOrient() async {
    final src = _src;
    if (src == null) return;
    setState(() => _busy = true);
    try {
      var best = _edit.rotation, bestCount = -1;
      for (final extra in [0, 90, 180, 270]) {
        final rot = (_edit.rotation + extra) % 360;
        final e = _edit.copyWith(rotation: rot, preset: FilterPreset.grayscale).resetAdjustments();
        final bytes = await renderPreview(src, e.toJson(), maxDim: 1000);
        final tmp = AppStorage.instance.tempPath('orient_$rot.jpg');
        await File(tmp).writeAsBytes(bytes);
        final n = await ocrService.textAmount(tmp, ref.read(settingsProvider).ocrScript);
        if (n > bestCount) {
          bestCount = n;
          best = rot;
        }
      }
      if (!mounted) return;
      final before = _edit.rotation;
      if (bestCount <= 5) {
        showSnack(context, 'Not enough text to detect orientation');
      } else {
        _set(_edit.copyWith(rotation: best), immediate: true);
        showSnack(context, best == before ? 'Orientation looks correct' : 'Rotated to $best°');
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final repo = ref.read(repositoryProvider);
    final hadOcr = widget.page.hasOcr;
    final r = await runBusy(context, 'Applying changes…', (ctl) => repo.updatePageEdit(widget.page, _edit));
    if (r != null && mounted) {
      if (hadOcr) showSnack(context, 'Page updated. Run OCR again to refresh its text.');
      Navigator.pop(context, true);
    }
  }

  Future<void> _revertAll() async {
    final ok = await confirm(context, 'Revert to original?', 'Removes crop, rotation, filter and adjustments. The original capture is always kept.', ok: 'Revert');
    if (ok) {
      _set(const PageEdit(), immediate: true);
      _thumbs.clear();
      _renderThumbs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit page'),
        actions: [
          PopupMenuButton<_Compare>(
            tooltip: 'Compare with original',
            icon: const Icon(Icons.compare),
            initialValue: _compare,
            onSelected: (v) => setState(() => _compare = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Compare.off, child: Text('Edited only')),
              PopupMenuItem(value: _Compare.original, child: Text('Show original')),
              PopupMenuItem(value: _Compare.sideBySide, child: Text('Side by side')),
            ],
          ),
          IconButton(onPressed: _revertAll, icon: const Icon(Icons.restore), tooltip: 'Revert all'),
          TextButton(onPressed: _preview == null ? null : _save, child: const Text('Save')),
        ],
      ),
      body: Column(children: [
        Expanded(child: _previewArea(scheme)),
        if (_busy) const LinearProgressIndicator(),
        _tabBody(),
      ]),
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == 2) {
            _crop();
            return;
          }
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.filter_vintage_outlined), label: 'Filters'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Adjust'),
          NavigationDestination(icon: Icon(Icons.crop), label: 'Crop'),
          NavigationDestination(icon: Icon(Icons.rotate_90_degrees_cw_outlined), label: 'Rotate'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }

  Widget _previewArea(ColorScheme scheme) {
    if (_error != null) return Center(child: Text(_error!));
    final edited = _preview == null
        ? const Center(child: CircularProgressIndicator())
        : InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(_preview!, gaplessPlayback: true)));
    final src = _src;
    final original = src == null ? const SizedBox() : InteractiveViewer(maxScale: 6, child: Center(child: Image.file(File(src))));
    Widget label(String t) => Positioned(
          left: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
            child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        );
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.all(8),
      child: switch (_compare) {
        _Compare.off => Stack(children: [Positioned.fill(child: edited), label(_edit.preset.label)]),
        _Compare.original => Stack(children: [Positioned.fill(child: original), label('Original (unchanged)')]),
        _Compare.sideBySide => Row(children: [
            Expanded(child: Stack(children: [Positioned.fill(child: original), label('Original')])),
            const SizedBox(width: 6),
            Expanded(child: Stack(children: [Positioned.fill(child: edited), label('Enhanced')])),
          ]),
      },
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 0:
        return SizedBox(
          height: 150,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            children: [
              for (final p in FilterPreset.values)
                GestureDetector(
                  onTap: () => _set(_edit.copyWith(preset: p), immediate: true),
                  child: Container(
                    width: 92,
                    margin: const EdgeInsets.only(right: 8),
                    child: Column(children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _edit.preset == p ? Theme.of(context).colorScheme.primary : Colors.transparent,
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _thumbs[p] == null
                              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                              : Image.memory(_thumbs[p]!, fit: BoxFit.cover, width: 92, gaplessPlayback: true),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(p.label, maxLines: 2, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
            ],
          ),
        );
      case 1:
        {
        final e = _edit;
        return SizedBox(
          height: 230,
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            if (e.preset.usesThreshold) ...[
              SwitchListTile(
                dense: true,
                title: const Text('Adaptive threshold'),
                subtitle: const Text('Keeps thin text in uneven light (recommended)'),
                value: e.adaptiveBw,
                onChanged: (v) => _set(e.copyWith(adaptiveBw: v), immediate: true),
              ),
              LabeledSlider(label: 'Threshold', value: e.threshold, onChanged: (v) => _set(e.copyWith(threshold: v))),
            ],
            LabeledSlider(label: 'Brightness', value: e.brightness, onChanged: (v) => _set(e.copyWith(brightness: v))),
            LabeledSlider(label: 'Contrast', value: e.contrast, onChanged: (v) => _set(e.copyWith(contrast: v))),
            LabeledSlider(label: 'Highlights', value: e.highlights, onChanged: (v) => _set(e.copyWith(highlights: v))),
            LabeledSlider(label: 'Shadows', value: e.shadows, onChanged: (v) => _set(e.copyWith(shadows: v))),
            if (!e.preset.usesThreshold) ...[
              LabeledSlider(label: 'Saturation', value: e.saturation, onChanged: (v) => _set(e.copyWith(saturation: v))),
              LabeledSlider(label: 'Sharpness', value: e.sharpness, min: 0, onChanged: (v) => _set(e.copyWith(sharpness: v))),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => _set(e.resetAdjustments(), immediate: true), child: const Text('Reset adjustments')),
            ),
          ]),
        );
        }
      case 3:
        return SizedBox(
          height: 150,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton.filledTonal(
                  onPressed: () => _set(_edit.copyWith(rotation: (_edit.rotation + 270) % 360), immediate: true),
                  icon: const Icon(Icons.rotate_left),
                  tooltip: 'Rotate left',
                ),
                IconButton.filledTonal(
                  onPressed: () => _set(_edit.copyWith(rotation: (_edit.rotation + 90) % 360), immediate: true),
                  icon: const Icon(Icons.rotate_right),
                  tooltip: 'Rotate right',
                ),
                OutlinedButton.icon(onPressed: _busy ? null : _autoDeskew, icon: const Icon(Icons.straighten), label: const Text('Auto-straighten')),
                OutlinedButton.icon(onPressed: _busy ? null : _autoOrient, icon: const Icon(Icons.screen_rotation_alt), label: const Text('Auto-orient')),
              ]),
              LabeledSlider(
                label: 'Fine angle',
                value: _edit.fineAngle,
                min: -15,
                max: 15,
                format: (v) => '${v.toStringAsFixed(1)}°',
                onChanged: (v) => _set(_edit.copyWith(fineAngle: (v * 10).round() / 10)),
              ),
            ]),
          ),
        );
      default:
        return SizedBox(
          height: 170,
          child: ListView(children: [
            SwitchListTile(
              title: const Text('Flatten curved page (approximate)'),
              subtitle: const Text('For book pages: straightens the top and bottom page edges. Results are approximate; the original is kept.'),
              value: _edit.flatten,
              onChanged: (v) => _set(_edit.copyWith(flatten: v), immediate: true),
            ),
            ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('Official document preservation'),
              subtitle: const Text('Gentle correction that protects stamps, seals and signatures'),
              onTap: () => setState(() {
                _set(_edit.copyWith(preset: FilterPreset.officialPreserve).resetAdjustments(), immediate: true);
                _compare = _Compare.sideBySide;
              }),
            ),
          ]),
        );
    }
  }
}
