import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../imaging/processor.dart';
import 'storage.dart';

class ImportedImage {
  final String path;
  final bool downscaled;
  const ImportedImage(this.path, this.downscaled);
}

/// Picking and normalising user-supplied images.
class ImportService {
  static const _directExt = ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'];
  static const _maxConvertPixels = 16000000;

  /// Opens the Android Photo Picker (no storage permission needed).
  static Future<List<String>> pickImages({bool multiple = true}) async {
    final picker = ImagePicker();
    if (multiple) {
      final files = await picker.pickMultiImage(requestFullMetadata: false);
      return files.map((f) => f.path).toList();
    }
    final f = await picker.pickImage(source: ImageSource.gallery, requestFullMetadata: false);
    return f == null ? const [] : [f.path];
  }

  /// Captures one photo with the system camera app.
  static Future<String?> captureWithSystemCamera({bool front = false}) async {
    final f = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
      requestFullMetadata: false,
    );
    return f?.path;
  }

  /// Picks image files through the system document picker (any provider).
  static Future<List<String>> pickImageFiles() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    if (r == null) return const [];
    return r.files.map((f) => f.path).whereType<String>().toList();
  }

  /// Returns a path the processing pipeline can decode. Common formats are
  /// used as-is (byte-for-byte originals). HEIC/other platform formats and
  /// extremely large images are decoded by the platform and re-encoded.
  static Future<ImportedImage> normalize(String path) async {
    final file = File(path);
    if (!await file.exists()) throw const FileSystemException('The selected file is no longer available.');
    final length = await file.length();
    if (length == 0) throw const FormatException('The selected file is empty.');
    final ext = p.extension(path).toLowerCase();
    final bytes = await file.readAsBytes();
    ui.ImageDescriptor? desc;
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buf);
    } catch (_) {
      desc = null;
    }
    if (desc == null) {
      if (_directExt.contains(ext)) return ImportedImage(path, false);
      throw const FormatException('This file is not a supported image.');
    }
    final w = desc.width, h = desc.height;
    final px = w * h;
    if (_directExt.contains(ext) && px <= maxSourcePixels) {
      desc.dispose();
      return ImportedImage(path, false);
    }
    final scale = px > _maxConvertPixels ? math.sqrt(_maxConvertPixels / px) : 1.0;
    final codec = await desc.instantiateCodec(
      targetWidth: math.max(1, (w * scale).floor()),
      targetHeight: math.max(1, (h * scale).floor()),
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw const FormatException('Could not decode the image.');
      final out = AppStorage.instance.tempPath('import.jpg');
      await rgbaToJpegFile(data.buffer.asUint8List(), image.width, image.height, out);
      image.dispose();
      return ImportedImage(out, scale < 1.0);
    } finally {
      codec.dispose();
      desc.dispose();
    }
  }
}
