import 'dart:typed_data';

import 'engine_worker.dart' show RenderedPage;
import 'pdf_edit_engine.dart';
import 'pdfium_engine.dart';

/// Operations served by the PDFium host isolate beyond the editor's own.
/// [s] is the session the call addresses (null for stateless operations).
Object? runHostOp(String op, PdfiumSession? s, List<Object?> args, PdfiumEngine engine) {
  PdfiumSession need() => s ?? (throw const PdfEditException('No document is open.'));
  switch (op) {
    case 'content':
      return need().content(args[0] as int, images: args.length > 1 ? args[1] as bool : true);
    case 'renderEncoded':
      return need().renderEncoded(args[0] as int,
          dpi: args[1] as double, format: RasterFormat.values[args[2] as int], quality: args[3] as int, grayscale: args[4] as bool);
    case 'renderOriginal':
      final r = need().renderOriginal(args[0] as int, args[1] as double);
      return RenderedPage(r.rgba, r.width, r.height);
    case 'pageSize':
      return need().pageSize(args[0] as int);
    case 'outline':
      return need().outline();
    case 'search':
      return need().search(args[0] as String, matchCase: args.length > 1 && args[1] == true);
    case 'pageText':
      return need().pageText(args[0] as int);
    case 'annotations':
      return need().annotations();
    case 'redact':
      return need().redact(args[0] as Map<int, List<RedactArea>>, options: args[1] as RedactOptions);
    case 'optimize':
      return need().optimizeImages(args[0] as ImageOptimizeOptions);
    case 'repair':
      return PdfiumSession.repair(args[0] as Uint8List, password: args[1] as String?);
    case 'insertPages':
      return need().insertPatternPages(args[0] as List<PatternPage>);
    case 'replacePages':
      return need().replacePages(args[0] as Uint8List, args[1] as String?, args[2] as Map<int, int>);
    default:
      throw PdfEditException('Unknown PDF operation "$op".');
  }
}
