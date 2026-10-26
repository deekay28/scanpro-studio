import 'dart:typed_data';
import 'dart:ui';

import 'package:xml/xml.dart';

import '../model/doc_model.dart';
import 'opc.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class SlideParagraph {
  final List<DocRun> runs;
  final int level;
  final bool bullet;
  final ParaAlign align;
  const SlideParagraph(this.runs, {this.level = 0, this.bullet = false, this.align = ParaAlign.left});
  String get text => runs.map((r) => r.text).join();
}

sealed class SlideShape {
  final Rect box; // points
  const SlideShape(this.box);
}

class SlideText extends SlideShape {
  final List<SlideParagraph> paras;
  final bool title;
  const SlideText(super.box, this.paras, {this.title = false});
  String get text => paras.map((p) => p.text).join('\n');
}

class SlidePicture extends SlideShape {
  final Uint8List bytes;
  final String? label; // alt text
  const SlidePicture(super.box, this.bytes, {this.label});
  bool get isJpeg => bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
}

class SlideTable extends SlideShape {
  final List<List<String>> rows;
  final bool header;
  const SlideTable(super.box, this.rows, {this.header = true});
}

class ChartSeries {
  final String name;
  final List<double?> values;
  const ChartSeries(this.name, this.values);
}

class ChartData {
  final String type; // bar, line, pie, area, scatter, ...
  final String title;
  final List<String> categories;
  final List<ChartSeries> series;
  final bool hasData; // false when the chart part has no cached values
  const ChartData(this.type, this.title, this.categories, this.series, {this.hasData = true});
}

class SlideChart extends SlideShape {
  final ChartData data;
  const SlideChart(super.box, this.data);
}

class SlideModel {
  final List<SlideShape> shapes;
  const SlideModel(this.shapes);
  String get title {
    for (final s in shapes) {
      if (s is SlideText && s.title) return s.text;
    }
    for (final s in shapes) {
      if (s is SlideText && s.text.trim().isNotEmpty) return s.text.split('\n').first;
    }
    return '';
  }
}

class PresentationModel {
  final double width; // points
  final double height;
  final List<SlideModel> slides;
  final String title;
  const PresentationModel(this.slides, {this.width = 720, this.height = 405, this.title = ''});
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

const _p = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _c = 'http://schemas.openxmlformats.org/drawingml/2006/chart';
int _emu(double pt) => (pt * 12700).round();
String _hex(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// Writes a PPTX (PresentationML) with editable text boxes, pictures,
/// native tables and native charts.
Uint8List writePptx(PresentationModel m) {
  if (m.slides.isEmpty) throw ArgumentError('A presentation needs at least one slide');
  final opc = OpcWriter();
  final presRels = Rels();
  final masterRid = presRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster', 'slideMasters/slideMaster1.xml');
  final sldIds = StringBuffer();
  var media = 0, charts = 0;
  for (var i = 0; i < m.slides.length; i++) {
    final rid = presRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide', 'slides/slide${i + 1}.xml');
    sldIds.write('<p:sldId id="${256 + i}" r:id="$rid"/>');
    final rels = Rels()..add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout', '../slideLayouts/slideLayout1.xml');
    final tree = StringBuffer();
    var id = 2;
    for (final s in m.slides[i].shapes) {
      final off = '<a:xfrm><a:off x="${_emu(s.box.left)}" y="${_emu(s.box.top)}"/><a:ext cx="${_emu(s.box.width)}" cy="${_emu(s.box.height)}"/></a:xfrm>';
      switch (s) {
        case SlideText t:
          tree.write('<p:sp><p:nvSpPr><p:cNvPr id="${id++}" name="${t.title ? 'Title' : 'TextBox'} $id"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
              '<p:spPr>$off<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
              '<p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>');
          for (final para in t.paras) {
            final algn = switch (para.align) { ParaAlign.center => 'ctr', ParaAlign.right => 'r', ParaAlign.justify => 'just', _ => 'l' };
            tree.write('<a:p><a:pPr lvl="${para.level.clamp(0, 8)}" algn="$algn"${para.bullet ? ' marL="${228600 * (para.level + 1)}" indent="-228600"' : ''}>'
                '${para.bullet ? '<a:buFont typeface="Arial"/><a:buChar char="•"/>' : '<a:buNone/>'}</a:pPr>');
            for (final r in para.runs) {
              if (r.text.isEmpty) continue;
              tree.write('<a:r><a:rPr lang="en-US"${r.size != null ? ' sz="${(r.size! * 100).round().clamp(100, 400000)}"' : ''}${r.bold ? ' b="1"' : ''}${r.italic ? ' i="1"' : ''} dirty="0">'
                  '${r.color != null ? '<a:solidFill><a:srgbClr val="${_hex(r.color!)}"/></a:solidFill>' : ''}'
                  '${r.font != null && r.font!.isNotEmpty ? '<a:latin typeface="${xmlEscape(r.font!)}"/>' : ''}</a:rPr><a:t>${xmlEscape(r.text)}</a:t></a:r>');
            }
            tree.write('<a:endParaRPr lang="en-US" dirty="0"/></a:p>');
          }
          if (t.paras.isEmpty) tree.write('<a:p><a:endParaRPr lang="en-US"/></a:p>');
          tree.write('</p:txBody></p:sp>');
        case SlidePicture pic:
          media++;
          final path = 'media/image$media.${pic.isJpeg ? 'jpeg' : 'png'}';
          opc.addBinary('ppt/$path', pic.bytes);
          final r = rels.add(relImage, '../$path');
          tree.write('<p:pic><p:nvPicPr><p:cNvPr id="${id++}" name="Picture $id" descr="${xmlEscape(pic.label ?? '')}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
              '<p:blipFill><a:blip r:embed="$r"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
              '<p:spPr>$off<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>');
        case SlideTable tbl:
          final cols = tbl.rows.fold<int>(0, (mx, r) => r.length > mx ? r.length : mx);
          if (cols == 0) continue;
          final cw = _emu(s.box.width / cols);
          final rh = _emu(s.box.height / tbl.rows.length);
          tree.write('<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="${id++}" name="Table $id"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
              '<p:xfrm><a:off x="${_emu(s.box.left)}" y="${_emu(s.box.top)}"/><a:ext cx="${cw * cols}" cy="${rh * tbl.rows.length}"/></p:xfrm>'
              '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr firstRow="${tbl.header ? 1 : 0}" bandRow="1"/><a:tblGrid>');
          for (var c = 0; c < cols; c++) {
            tree.write('<a:gridCol w="$cw"/>');
          }
          tree.write('</a:tblGrid>');
          final fontSize = (s.box.height / tbl.rows.length * 0.45).clamp(7.0, 18.0);
          for (var r = 0; r < tbl.rows.length; r++) {
            tree.write('<a:tr h="$rh">');
            for (var c = 0; c < cols; c++) {
              final text = c < tbl.rows[r].length ? tbl.rows[r][c] : '';
              final head = r == 0 && tbl.header;
              tree.write('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="${(fontSize * 100).round()}"${head ? ' b="1"' : ''}>'
                  '${head ? '<a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>' : ''}</a:rPr><a:t>${xmlEscape(text)}</a:t></a:r></a:p></a:txBody>'
                  '<a:tcPr marL="45720" marR="45720" marT="22860" marB="22860">'
                  '<a:lnL w="6350"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:lnL><a:lnR w="6350"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:lnR>'
                  '<a:lnT w="6350"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:lnT><a:lnB w="6350"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:lnB>'
                  '<a:solidFill><a:srgbClr val="${head ? '1F4E79' : (r.isEven ? 'F2F2F2' : 'FFFFFF')}"/></a:solidFill></a:tcPr></a:tc>');
            }
            tree.write('</a:tr>');
          }
          tree.write('</a:tbl></a:graphicData></a:graphic></p:graphicFrame>');
        case SlideChart ch:
          charts++;
          final path = 'charts/chart$charts.xml';
          opc.addXml('ppt/$path', _chartXml(ch.data), contentType: 'application/vnd.openxmlformats-officedocument.drawingml.chart+xml');
          final r = rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart', '../$path');
          tree.write('<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="${id++}" name="Chart $id"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
              '<p:xfrm><a:off x="${_emu(s.box.left)}" y="${_emu(s.box.top)}"/><a:ext cx="${_emu(s.box.width)}" cy="${_emu(s.box.height)}"/></p:xfrm>'
              '<a:graphic><a:graphicData uri="$_c"><c:chart xmlns:c="$_c" r:id="$r"/></a:graphicData></a:graphic></p:graphicFrame>');
      }
    }
    final slide = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_p"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>$tree</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
    opc.addXml('ppt/slides/slide${i + 1}.xml', slide, contentType: 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml');
    opc.addXml('ppt/slides/_rels/slide${i + 1}.xml.rels', rels.xml());
  }
  final themeRid = presRels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme', 'theme/theme1.xml');
  assert(themeRid.isNotEmpty);
  final cx = _emu(m.width), cy = _emu(m.height);
  opc.addXml(
      'ppt/presentation.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<p:presentation xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_p" saveSubsetFonts="1">'
          '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="$masterRid"/></p:sldMasterIdLst>'
          '<p:sldIdLst>$sldIds</p:sldIdLst><p:sldSz cx="$cx" cy="$cy"/><p:notesSz cx="6858000" cy="9144000"/>'
          '<p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>',
      contentType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml');
  opc.addXml('ppt/_rels/presentation.xml.rels', presRels.xml());
  opc.addXml(
      'ppt/slideMasters/slideMaster1.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<p:sldMaster xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_p"><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>'
          '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
          '</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
          '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
          '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="3200"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>',
      contentType: 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml');
  opc.addXml(
      'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      (Rels()
            ..add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout', '../slideLayouts/slideLayout1.xml')
            ..add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme', '../theme/theme1.xml'))
          .xml());
  opc.addXml(
      'ppt/slideLayouts/slideLayout1.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<p:sldLayout xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_p" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>'
          '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
          '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>',
      contentType: 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml');
  opc.addXml('ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      (Rels()..add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster', '../slideMasters/slideMaster1.xml')).xml());
  opc.addXml('ppt/theme/theme1.xml', _theme, contentType: 'application/vnd.openxmlformats-officedocument.theme+xml');
  final root = Rels()
    ..add(relOfficeDoc, 'ppt/presentation.xml')
    ..add(relCore, 'docProps/core.xml')
    ..add(relApp, 'docProps/app.xml');
  opc.addXml('_rels/.rels', root.xml());
  opc.addXml('docProps/core.xml', corePropsXml(m.title), contentType: 'application/vnd.openxmlformats-package.core-properties+xml');
  opc.addXml('docProps/app.xml', appPropsXml(), contentType: 'application/vnd.openxmlformats-officedocument.extended-properties+xml');
  return opc.finish();
}

String _chartXml(ChartData d) {
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<c:chartSpace xmlns:c="$_c" xmlns:a="$_a" xmlns:r="$_r"><c:roundedCorners val="0"/><c:chart>');
  if (d.title.isNotEmpty) {
    sb.write('<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>${xmlEscape(d.title)}</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>');
  }
  sb.write('<c:autoTitleDeleted val="${d.title.isEmpty ? 1 : 0}"/><c:plotArea><c:layout/><c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>');
  for (var i = 0; i < d.series.length; i++) {
    final s = d.series[i];
    sb.write('<c:ser><c:idx val="$i"/><c:order val="$i"/><c:tx><c:v>${xmlEscape(s.name)}</c:v></c:tx><c:invertIfNegative val="0"/>');
    sb.write('<c:cat><c:strLit><c:ptCount val="${d.categories.length}"/>');
    for (var k = 0; k < d.categories.length; k++) {
      sb.write('<c:pt idx="$k"><c:v>${xmlEscape(d.categories[k])}</c:v></c:pt>');
    }
    sb.write('</c:strLit></c:cat><c:val><c:numLit><c:formatCode>General</c:formatCode><c:ptCount val="${s.values.length}"/>');
    for (var k = 0; k < s.values.length; k++) {
      final v = s.values[k];
      if (v != null) sb.write('<c:pt idx="$k"><c:v>$v</c:v></c:pt>');
    }
    sb.write('</c:numLit></c:val></c:ser>');
  }
  sb.write('<c:gapWidth val="150"/><c:axId val="111111111"/><c:axId val="222222222"/></c:barChart>'
      '<c:catAx><c:axId val="111111111"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:numFmt formatCode="General" sourceLinked="0"/><c:tickLblPos val="nextTo"/><c:crossAx val="222222222"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/></c:catAx>'
      '<c:valAx><c:axId val="222222222"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="0"/><c:tickLblPos val="nextTo"/><c:crossAx val="111111111"/><c:crosses val="autoZero"/><c:crossBetween val="between"/></c:valAx>'
      '</c:plotArea><c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/></c:chart></c:chartSpace>');
  return sb.toString();
}

const _theme = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<a:theme xmlns:a="$_a" name="ScanPro"><a:themeElements>'
    '<a:clrScheme name="ScanPro"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F4E79"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>'
    '<a:accent1><a:srgbClr val="1F77B4"/></a:accent1><a:accent2><a:srgbClr val="FF7F0E"/></a:accent2><a:accent3><a:srgbClr val="2CA02C"/></a:accent3>'
    '<a:accent4><a:srgbClr val="D62728"/></a:accent4><a:accent5><a:srgbClr val="9467BD"/></a:accent5><a:accent6><a:srgbClr val="8C564B"/></a:accent6>'
    '<a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>'
    '<a:fontScheme name="ScanPro"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
    '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
    '<a:fmtScheme name="ScanPro"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
    '<a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
    '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
    '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>'
    '</a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>';

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// Reads slides: text (with bullet levels, titles), pictures, tables and
/// charts (from the values cached in the chart part; never invented).
PresentationModel readPptx(Uint8List bytes) {
  final opc = OpcReader(bytes);
  var presPath = 'ppt/presentation.xml';
  for (final r in opc.rels('').values) {
    if (r.$1.endsWith('/officeDocument')) presPath = r.$2;
  }
  final pres = opc.xml(presPath);
  if (pres == null) throw const FormatException('This PPTX has no presentation part.');
  final rels = opc.rels(presPath);
  final sz = pres.rootElement.kid('sldSz');
  final w = (double.tryParse(sz?.attr('cx') ?? '') ?? 9144000) / 12700;
  final h = (double.tryParse(sz?.attr('cy') ?? '') ?? 5143500) / 12700;
  final slides = <SlideModel>[];
  for (final id in pres.rootElement.all('sldId')) {
    final rel = rels[id.rid ?? ''];
    if (rel == null) continue;
    final x = opc.xml(rel.$2);
    if (x == null) continue;
    final srels = opc.rels(rel.$2);
    // Placeholder positions inherited from the layout and master.
    final inherited = <String, Rect>{};
    void collect(String? part) {
      if (part == null) return;
      final px = opc.xml(part);
      if (px == null) return;
      for (final sp in px.rootElement.all('sp')) {
        final ph = sp.all('ph').firstOrNull;
        final r = _xfrmRect(sp);
        if (ph == null || r == null) continue;
        final type = ph.attr('type') ?? 'body';
        final idx = ph.attr('idx');
        inherited.putIfAbsent('t:$type', () => r);
        if (idx != null) inherited.putIfAbsent('i:$idx', () => r);
      }
    }

    String? relOfType(Map<String, (String, String)> rs, String t) {
      for (final r in rs.values) {
        if (r.$1.endsWith('/$t')) return r.$2;
      }
      return null;
    }

    final layout = relOfType(srels, 'slideLayout');
    collect(layout);
    collect(layout == null ? null : relOfType(opc.rels(layout), 'slideMaster'));
    final shapes = <SlideShape>[];
    void walk(XmlElement tree) {
      for (final e in tree.childElements) {
        Rect box() {
          final own = _xfrmRect(e);
          if (own != null) return own;
          final ph = e.all('ph').firstOrNull;
          if (ph != null) {
            final type = ph.attr('type') ?? 'body';
            final r = (ph.attr('idx') != null ? inherited['i:${ph.attr('idx')}'] : null) ?? inherited['t:$type'] ?? (type == 'ctrTitle' ? inherited['t:title'] : null);
            if (r != null) return r;
            if (type == 'title' || type == 'ctrTitle') return Rect.fromLTWH(w * 0.05, h * 0.04, w * 0.9, h * 0.18);
          }
          return Rect.fromLTWH(w * 0.05, h * 0.25, w * 0.9, h * 0.65);
        }

        switch (e.local) {
          case 'sp':
            final body = e.kid('txBody');
            if (body == null) continue;
            final ph = e.all('ph').firstOrNull?.attr('type');
            final paras = <SlideParagraph>[];
            for (final p in body.kids('p')) {
              final pPr = p.kid('pPr');
              final lvl = int.tryParse(pPr?.attr('lvl') ?? '0') ?? 0;
              final bullet = pPr?.kid('buChar') != null || pPr?.kid('buAutoNum') != null || (ph == 'body' || ph == null) && pPr?.kid('buNone') == null && lvl > 0;
              final runs = <DocRun>[];
              for (final r in p.childElements) {
                if (r.local == 'r' || r.local == 'fld') {
                  final rPr = r.kid('rPr');
                  final szv = rPr?.attr('sz');
                  final col = rPr?.all('srgbClr').firstOrNull?.attr('val');
                  runs.add(DocRun(r.kid('t')?.innerText ?? '',
                      bold: rPr?.attr('b') == '1',
                      italic: rPr?.attr('i') == '1',
                      size: szv == null ? null : (double.tryParse(szv) ?? 1800) / 100,
                      color: col == null ? null : 0xFF000000 | (int.tryParse(col, radix: 16) ?? 0)));
                } else if (r.local == 'br') {
                  runs.add(const DocRun('\n'));
                }
              }
              final algn = switch (pPr?.attr('algn')) { 'ctr' => ParaAlign.center, 'r' => ParaAlign.right, 'just' => ParaAlign.justify, _ => ParaAlign.left };
              paras.add(SlideParagraph(runs, level: lvl, bullet: bullet, align: algn));
            }
            if (paras.any((p) => p.text.trim().isNotEmpty)) shapes.add(SlideText(box(), paras, title: ph == 'title' || ph == 'ctrTitle'));
          case 'pic':
            final emb = e.all('blip').firstOrNull?.attr('embed');
            final data = emb == null ? null : (srels[emb] == null ? null : opc.bytes(srels[emb]!.$2));
            if (data != null) shapes.add(SlidePicture(box(), data, label: e.all('cNvPr').firstOrNull?.attr('descr')));
          case 'graphicFrame':
            final tbl = e.all('tbl').firstOrNull;
            if (tbl != null) {
              final rows = [
                for (final tr in tbl.kids('tr')) [for (final tc in tr.kids('tc')) tc.all('t').map((t) => t.innerText).join()]
              ];
              shapes.add(SlideTable(box(), rows, header: tbl.kid('tblPr')?.attr('firstRow') == '1'));
              continue;
            }
            final chartRef = e.all('chart').firstOrNull?.rid;
            if (chartRef != null && srels[chartRef] != null) {
              final cx = opc.xml(srels[chartRef]!.$2);
              if (cx != null) shapes.add(SlideChart(box(), _readChart(cx)));
            }
          case 'grpSp':
            walk(e);
        }
      }
    }

    final tree = x.rootElement.all('spTree').firstOrNull;
    if (tree != null) walk(tree);
    slides.add(SlideModel(shapes));
  }
  return PresentationModel(slides, width: w, height: h, title: opc.xml('docProps/core.xml')?.rootElement.all('title').firstOrNull?.innerText ?? '');
}

Rect? _xfrmRect(XmlElement e) {
  final xfrm = e.all('xfrm').firstOrNull;
  final off = xfrm?.kid('off'), ext = xfrm?.kid('ext');
  if (off == null || ext == null) return null;
  double v(XmlElement el, String a) => (double.tryParse(el.attr(a) ?? '') ?? 0) / 12700;
  final r = Rect.fromLTWH(v(off, 'x'), v(off, 'y'), v(ext, 'cx'), v(ext, 'cy'));
  return r.width <= 0 && r.height <= 0 ? null : r;
}

ChartData _readChart(XmlDocument x) {
  final root = x.rootElement;
  final title = root.kid('chart')?.kid('title')?.all('t').map((t) => t.innerText).join() ?? '';
  final plot = root.all('plotArea').firstOrNull;
  var type = 'chart';
  final series = <ChartSeries>[];
  var cats = <String>[];
  if (plot != null) {
    for (final c in plot.childElements) {
      if (!c.local.endsWith('Chart')) continue;
      type = c.local.replaceAll('Chart', '');
      for (final s in c.kids('ser')) {
        final name = s.kid('tx')?.all('v').firstOrNull?.innerText ?? 'Series ${series.length + 1}';
        List<String?> pts(XmlElement? el) {
          if (el == null) return const [];
          final count = int.tryParse(el.all('ptCount').firstOrNull?.attr('val') ?? '') ?? 0;
          final out = List<String?>.filled(count, null, growable: true);
          for (final pt in el.all('pt')) {
            final i = int.tryParse(pt.attr('idx') ?? '') ?? -1;
            if (i < 0) continue;
            while (out.length <= i) {
              out.add(null);
            }
            out[i] = pt.kid('v')?.innerText;
          }
          return out;
        }

        final catPts = pts(s.kid('cat') ?? s.kid('xVal'));
        if (catPts.isNotEmpty && cats.isEmpty) cats = catPts.map((e) => e ?? '').toList();
        final vals = pts(s.kid('val') ?? s.kid('yVal')).map((v) => v == null ? null : double.tryParse(v)).toList();
        series.add(ChartSeries(name, vals));
      }
    }
  }
  final hasData = series.any((s) => s.values.any((v) => v != null));
  return ChartData(type, title, cats, series, hasData: hasData);
}
