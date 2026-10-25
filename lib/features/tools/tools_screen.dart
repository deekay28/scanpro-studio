import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup_screen.dart';
import '../book/book_scan_screen.dart';
import '../ocr/quick_ocr_screen.dart';
import '../passport/calibration_screen.dart';
import '../pdf/pdf_tools_screen.dart';
import '../qr/qr_screen.dart';
import '../scanner/scan_flow.dart';
import '../security/vault.dart';

class ToolsScreen extends ConsumerWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    final sections = <(String, List<(IconData, String, String, VoidCallback)>)>[
      (
        'PDF tools',
        [
          (Icons.picture_as_pdf_outlined, 'Images to PDF', 'Create a multi-page PDF', () => ScanFlow.importImages(context, ref)),
          (Icons.merge_type, 'Merge PDFs', 'Combine files in any order', () => PdfTools.merge(context, ref)),
          (Icons.call_split, 'Split / extract', 'By page ranges', () => PdfTools.pickThen(context, ref, 'split')),
          (Icons.view_module_outlined, 'Organise pages', 'Reorder, rotate, delete, insert', () => PdfTools.pickThen(context, ref, 'organize')),
          (Icons.compress, 'Compress PDF', 'Email, messaging or print', () => PdfTools.pickThen(context, ref, 'compress')),
          (Icons.lock_outline, 'Protect PDF', 'AES-256 password', () => PdfTools.pickThen(context, ref, 'protect')),
          (Icons.lock_open, 'Remove password', 'Needs the current password', () => PdfTools.pickThen(context, ref, 'unlock')),
          (Icons.image_outlined, 'PDF to images', 'PNG pages or editable scan', () => PdfTools.pickThen(context, ref, 'images')),
          (Icons.text_snippet_outlined, 'PDF text', 'Extract the text layer', () => PdfTools.pickThen(context, ref, 'text')),
          (Icons.visibility_outlined, 'View PDF', 'Preview, print, share', () => PdfTools.pickThen(context, ref, 'view')),
        ]
      ),
      (
        'Scan & recognise',
        [
          (Icons.text_fields, 'Image to text', 'On-device OCR (English, Hindi)', () => push(const QuickOcrScreen())),
          (Icons.menu_book, 'Book scanner', 'Split two-page spreads', () => push(const BookScanScreen())),
          (Icons.qr_code_scanner, 'Scan QR / barcode', 'From camera or image', () => push(const QrScanScreen())),
          (Icons.qr_code_2, 'Create QR code', 'Text or link to PNG', () => push(const QrGenerateScreen())),
        ]
      ),
      (
        'Printing & data',
        [
          (Icons.straighten, 'Print calibration page', 'Check your printer prints at 100%', () => push(const CalibrationScreen())),
          (Icons.enhanced_encryption_outlined, 'Private vault', 'Encrypted documents', () => push(const VaultScreen())),
          (Icons.backup_outlined, 'Backup & restore', 'ZIP export / import', () => push(const BackupScreen())),
        ]
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        for (final s in sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(s.$1, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          for (final t in s.$2)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(t.$1, color: Theme.of(context).colorScheme.onPrimaryContainer),
              ),
              title: Text(t.$2),
              subtitle: Text(t.$3),
              onTap: t.$4,
            ),
        ],
      ]),
    );
  }
}
