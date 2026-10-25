import 'package:flutter/material.dart';

import '../../core/units.dart';
import '../pdf/pdf_viewer_screen.dart';
import 'sheet_renderer.dart';

const printScaleWarning = 'For exact physical sizes:\n\n'
    '• Choose the same paper size in the print dialog as the sheet (e.g. A4 or 4×6 in).\n'
    '• Set scaling to 100% / "Actual size". Turn OFF "Fit to page", "Shrink to fit" or "Borderless enlargement".\n'
    '• Printer drivers and hardware margins can still shift or clip the output by a millimetre or so.\n\n'
    'Tip: print the calibration page first and measure it with a ruler.';

/// Generates a printable calibration chart to verify printer scaling.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  PaperSize _paper = PaperSizes.a4;

  void _open() {
    final bytes = SheetRenderer.calibrationPdf(_paper);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(
        bytes: bytes,
        title: 'Print calibration ${_paper.name}',
        offerSaveToLibrary: false,
        printWarning: printScaleWarning,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Print calibration')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Print this test page to check that your printer reproduces sizes exactly. '
          'The rulers must measure 100 mm and the squares 50 mm and 1 inch. If they do not, '
          'the printer driver is scaling the page — fix the print settings before printing passport photos.',
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          for (final p in [PaperSizes.a4, PaperSizes.letter])
            ChoiceChip(label: Text(p.name), selected: _paper.id == p.id, onSelected: (_) => setState(() => _paper = p)),
        ]),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _open, icon: const Icon(Icons.straighten), label: const Text('Create calibration page')),
      ]),
    );
  }
}
