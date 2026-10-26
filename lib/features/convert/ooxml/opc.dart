import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Minimal Open Packaging Conventions helpers shared by the DOCX, XLSX and
/// PPTX writers and readers.
class OpcWriter {
  final Archive _a = Archive();
  final Map<String, String> _overrides = {};
  final Map<String, String> _defaults = {
    'rels': 'application/vnd.openxmlformats-package.relationships+xml',
    'xml': 'application/xml',
    'png': 'image/png',
    'jpeg': 'image/jpeg',
    'jpg': 'image/jpeg',
  };

  void addXml(String path, String xml, {String? contentType}) {
    final bytes = utf8.encode(xml);
    _a.addFile(ArchiveFile(path, bytes.length, bytes));
    if (contentType != null) _overrides['/$path'] = contentType;
  }

  void addBinary(String path, Uint8List data) => _a.addFile(ArchiveFile(path, data.length, data));

  Uint8List finish() {
    final ct = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">');
    _defaults.forEach((ext, type) => ct.write('<Default Extension="$ext" ContentType="$type"/>'));
    _overrides.forEach((part, type) => ct.write('<Override PartName="$part" ContentType="$type"/>'));
    ct.write('</Types>');
    final bytes = utf8.encode(ct.toString());
    _a.addFile(ArchiveFile('[Content_Types].xml', bytes.length, bytes));
    return Uint8List.fromList(ZipEncoder().encode(_a)!);
  }
}

/// Relationship list builder.
class Rels {
  final List<(String, String, String, bool)> _r = []; // id, type, target, external
  String add(String type, String target, {bool external = false}) {
    final id = 'rId${_r.length + 1}';
    _r.add((id, type, target, external));
    return id;
  }

  String xml() {
    final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    for (final (id, type, target, ext) in _r) {
      sb.write('<Relationship Id="$id" Type="$type" Target="${_esc(target)}"${ext ? ' TargetMode="External"' : ''}/>');
    }
    sb.write('</Relationships>');
    return sb.toString();
  }

  static String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
}

const relOfficeDoc = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument';
const relCore = 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties';
const relApp = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties';
const relImage = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';
const relHyperlink = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink';

String corePropsXml(String title) {
  final now = DateTime.now().toUtc().toIso8601String().split('.').first;
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
      '<dc:title>${title.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</dc:title><dc:creator>ScanPro Studio</dc:creator>'
      '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
      '<dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified></cp:coreProperties>';
}

String appPropsXml() => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
    '<Application>ScanPro Studio</Application></Properties>';

/// Reads parts from an OPC zip package.
class OpcReader {
  final Archive _a;
  OpcReader(Uint8List bytes) : _a = _decode(bytes);

  static Archive _decode(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const FormatException('Not an Office Open XML file (DOCX/XLSX/PPTX). Older .doc/.xls/.ppt files are not supported.');
    }
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('The file is damaged or encrypted.');
    }
  }

  bool has(String path) => _a.findFile(path) != null;

  Uint8List? bytes(String path) {
    final f = _a.findFile(path.startsWith('/') ? path.substring(1) : path);
    if (f == null) return null;
    return Uint8List.fromList(f.content as List<int>);
  }

  XmlDocument? xml(String path) {
    final b = bytes(path);
    if (b == null) return null;
    return XmlDocument.parse(utf8.decode(b, allowMalformed: true));
  }

  /// Relationships of [part]: id → (type, absolute target path or URL).
  Map<String, (String, String)> rels(String part) {
    final dir = part.contains('/') ? part.substring(0, part.lastIndexOf('/')) : '';
    final name = part.substring(part.lastIndexOf('/') + 1);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/$name.rels');
    final out = <String, (String, String)>{};
    if (doc == null) return out;
    for (final r in doc.findAllElements('Relationship')) {
      final id = r.getAttribute('Id') ?? '';
      final type = r.getAttribute('Type') ?? '';
      final target = r.getAttribute('Target') ?? '';
      final external = r.getAttribute('TargetMode') == 'External';
      out[id] = (type, external ? target : resolve(dir, target));
    }
    return out;
  }

  static String resolve(String dir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [...(dir.isEmpty ? <String>[] : dir.split('/'))];
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.' && seg.isNotEmpty) {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }
}

/// Local name of an element (without prefix).
extension XmlLocal on XmlElement {
  String get local => name.local;
  Iterable<XmlElement> kids(String local) => childElements.where((e) => e.name.local == local);
  XmlElement? kid(String local) {
    for (final e in childElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  Iterable<XmlElement> all(String local) => descendants.whereType<XmlElement>().where((e) => e.name.local == local);
  /// The relationship id attribute (r:id), ignoring any plain `id`.
  String? get rid {
    for (final a in attributes) {
      if (a.name.local == 'id' && (a.name.namespaceUri?.endsWith('/relationships') ?? a.name.prefix == 'r')) return a.value;
    }
    for (final a in attributes) {
      if (a.name.qualified == 'r:id') return a.value;
    }
    return null;
  }

  String? attr(String local) {
    for (final a in attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }
}
