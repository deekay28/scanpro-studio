import 'package:flutter/material.dart';

import 'page_cache.dart';

/// A labelled rectangle on a page, in page points.
class PageArea {
  final int page;
  final Rect rect;
  final String label;
  final Color color;
  const PageArea(this.page, this.rect, {this.label = '', this.color = const Color(0x553F51B5)});
}

/// Shows one page at a time; dragging draws a new area (reported in page
/// points through [onDrawn]); tapping an existing area reports it through
/// [onTapArea]. Pinch to zoom is disabled while drawing so drags are exact.
class PageAreaPicker extends StatefulWidget {
  final PageRenderCache cache;
  final int page;
  final List<PageArea> areas;
  final void Function(Rect rect) onDrawn;
  final void Function(PageArea area)? onTapArea;
  final Color drawColor;
  const PageAreaPicker({
    super.key,
    required this.cache,
    required this.page,
    required this.areas,
    required this.onDrawn,
    this.onTapArea,
    this.drawColor = const Color(0x553F51B5),
  });

  @override
  State<PageAreaPicker> createState() => _PageAreaPickerState();
}

class _PageAreaPickerState extends State<PageAreaPicker> {
  Offset? _start, _end;

  @override
  Widget build(BuildContext context) {
    final size = widget.cache.sizes[widget.page];
    return LayoutBuilder(builder: (ctx, c) {
      final k = [c.maxWidth / size.width, c.maxHeight / size.height].reduce((a, b) => a < b ? a : b);
      final w = size.width * k, h = size.height * k;
      Rect toPage(Offset a, Offset b) => Rect.fromPoints(
            Offset((a.dx / k).clamp(0, size.width), (a.dy / k).clamp(0, size.height)),
            Offset((b.dx / k).clamp(0, size.width), (b.dy / k).clamp(0, size.height)),
          );
      final onPage = widget.areas.where((a) => a.page == widget.page).toList();
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            onPanStart: (d) => setState(() => _start = _end = d.localPosition),
            onPanUpdate: (d) => setState(() => _end = d.localPosition),
            onPanEnd: (_) {
              final s = _start, e = _end;
              setState(() => _start = _end = null);
              if (s == null || e == null) return;
              final r = toPage(s, e);
              if (r.width >= 4 && r.height >= 4) widget.onDrawn(r);
            },
            onTapUp: (d) {
              final p = d.localPosition / k;
              for (final a in onPage.reversed) {
                if (a.rect.inflate(4).contains(p)) {
                  widget.onTapArea?.call(a);
                  return;
                }
              }
            },
            child: Stack(children: [
              Container(decoration: BoxDecoration(boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)], color: Colors.white)),
              RenderedPageView(cache: widget.cache, page: widget.page, width: w),
              for (final a in onPage)
                Positioned(
                  left: a.rect.left * k,
                  top: a.rect.top * k,
                  width: a.rect.width * k,
                  height: a.rect.height * k,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(color: a.color, border: Border.all(color: a.color.withValues(alpha: 1), width: 1.5)),
                      alignment: Alignment.topLeft,
                      child: a.label.isEmpty
                          ? null
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Container(
                                color: Colors.white70,
                                padding: const EdgeInsets.symmetric(horizontal: 2),
                                child: Text(a.label, style: const TextStyle(fontSize: 10, color: Colors.black)),
                              ),
                            ),
                    ),
                  ),
                ),
              if (_start != null && _end != null)
                Positioned.fromRect(
                  rect: Rect.fromPoints(_start!, _end!),
                  child: IgnorePointer(child: Container(decoration: BoxDecoration(color: widget.drawColor, border: Border.all(color: widget.drawColor.withValues(alpha: 1))))),
                ),
            ]),
          ),
        ),
      );
    });
  }
}

/// Page selector shown under a [PageAreaPicker].
class PageStepper extends StatelessWidget {
  final int page;
  final int count;
  final ValueChanged<int> onChanged;
  const PageStepper({super.key, required this.page, required this.count, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: page > 0 ? () => onChanged(page - 1) : null),
        Text('Page ${page + 1} of $count'),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: page < count - 1 ? () => onChanged(page + 1) : null),
      ]);
}
