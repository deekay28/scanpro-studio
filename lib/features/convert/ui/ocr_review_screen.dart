import 'dart:io';

import 'package:flutter/material.dart';

import '../../../shared/widgets.dart';
import '../layout/ocr_review.dart';

/// Lists the words of a converted scan that OCR read with low confidence,
/// each with the line it was read in and where it is on the page, so they
/// can be checked against the original and corrected. Saving writes the
/// corrections into the Word document (only those words change); nothing is
/// corrected automatically. Words left out of the text (printed in a stamp,
/// or noise) are listed for information.
class OcrReviewScreen extends StatefulWidget {
  final String docxPath;
  final String name;
  const OcrReviewScreen({super.key, required this.docxPath, required this.name});

  static bool available(String docxPath) => File(reviewPathFor(docxPath)).existsSync();

  @override
  State<OcrReviewScreen> createState() => _OcrReviewScreenState();
}

class _OcrReviewScreenState extends State<OcrReviewScreen> {
  List<OcrReviewItem> _items = const [];
  List<Size> _pages = const [];
  final _fields = <int, TextEditingController>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final (items, pages) = decodeReview(File(reviewPathFor(widget.docxPath)).readAsStringSync());
    _items = items;
    _pages = pages;
    for (final i in items.where((x) => !x.omitted)) {
      _fields[i.id] = TextEditingController(text: i.text);
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Size _pageSize(int page) => page - 1 < _pages.length ? _pages[page - 1] : const Size(595, 842);

  Future<void> _save() async {
    final changes = <int, String>{
      for (final i in _items.where((x) => !x.omitted))
        if (_fields[i.id]!.text != i.text) i.id: _fields[i.id]!.text,
    };
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final f = File(widget.docxPath);
      final fixed = applyOcrCorrections(await f.readAsBytes(), changes);
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(fixed, flush: true);
      await tmp.rename(f.path);
      for (final i in _items) {
        if (changes[i.id] case final t?) i.text = t;
      }
      await File(reviewPathFor(widget.docxPath)).writeAsString(encodeReview(_items, _pages));
      if (!mounted) return;
      showSnack(context, '${changes.length} correction(s) saved in ${widget.name}');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Could not save: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = _items.where((x) => !x.omitted).toList();
    final omitted = _items.where((x) => x.omitted).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review OCR words'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            check.isEmpty
                ? 'No words were read with low confidence.'
                : 'These ${check.length} word(s) were read with low confidence. Compare them with the original and correct any mistakes; '
                    'only the words you change are written into the document. Names, dates and amounts are never changed automatically.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          for (final i in check)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${i.where(_pageSize(i.page))} · confidence ${i.confidence == null ? '–' : '${(i.confidence! * 100).round()}%'}',
                      style: Theme.of(context).textTheme.labelSmall),
                  Text('… ${i.context} …', maxLines: 2, overflow: TextOverflow.ellipsis),
                  TextField(controller: _fields[i.id], decoration: const InputDecoration(labelText: 'Text in the document')),
                ]),
              ),
            ),
          if (omitted.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Left out of the text', style: Theme.of(context).textTheme.titleSmall),
            const Text('Read by OCR but kept as part of a picture (text printed in a stamp or seal) or treated as noise. '
                'Add them in Word if they belong in the text.'),
            for (final i in omitted) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(i.text), subtitle: Text(i.where(_pageSize(i.page)))),
          ],
        ],
      ),
    );
  }
}
