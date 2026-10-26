import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../model/doc_model.dart';
import 'opc.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _wp = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _pic = 'http://schemas.openxmlformats.org/drawingml/2006/picture';

int _tw(double pt) => (pt * 20).round(); // twips
int _emu(double pt) => (pt * 12700).round();
String _hex(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// Writes a real, editable DOCX (WordprocessingML) from a [DocModel].
Uint8List writeDocx(DocModel m) {
  final opc = OpcWriter();
  final rels = Rels();
  rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles', 'styles.xml');
  rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering', 'numbering.xml');
  rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings', 'settings.xml');
  String? headerId, footerId;
  if (m.header.trim().isNotEmpty) {
    headerId = rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/header', 'header1.xml');
    opc.addXml('word/header1.xml', _hdrFtr('hdr', m.header), contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml');
  }
  if (m.footer.trim().isNotEmpty) {
    footerId = rels.add('http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer', 'footer1.xml');
    opc.addXml('word/footer1.xml', _hdrFtr('ftr', m.footer), contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml');
  }
  var imageNo = 0;
  var docPr = 1;
  final body = StringBuffer();

  String sect(double w, double h, {bool last = false}) {
    final sb = StringBuffer('<w:sectPr>');
    if (headerId != null) sb.write('<w:headerReference w:type="default" r:id="$headerId"/>');
    if (footerId != null) sb.write('<w:footerReference w:type="default" r:id="$footerId"/>');
    if (!last) sb.write('<w:type w:val="nextPage"/>');
    sb.write('<w:pgSz w:w="${_tw(w)}" w:h="${_tw(h)}"${w > h ? ' w:orient="landscape"' : ''}/>');
    final mg = _tw(m.margin);
    sb.write('<w:pgMar w:top="$mg" w:right="$mg" w:bottom="$mg" w:left="$mg" w:header="${_tw(m.margin / 2)}" w:footer="${_tw(m.margin / 2)}" w:gutter="0"/>');
    sb.write('</w:sectPr>');
    return sb.toString();
  }

  String runXml(DocRun r) {
    final pr = StringBuffer();
    if (r.font != null && r.font!.isNotEmpty) {
      final f = xmlEscape(r.font!);
      pr.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
    }
    if (r.bold) pr.write('<w:b/>');
    if (r.italic) pr.write('<w:i/>');
    if (r.underline || r.link != null) pr.write('<w:u w:val="single"/>');
    if (r.color != null && (r.color! & 0xFFFFFF) != 0) pr.write('<w:color w:val="${_hex(r.color!)}"/>');
    if (r.size != null) pr.write('<w:sz w:val="${(r.size! * 2).round().clamp(2, 3276)}"/><w:szCs w:val="${(r.size! * 2).round().clamp(2, 3276)}"/>');
    final parts = r.text.split('\n');
    final sb = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      sb.write('<w:r>');
      if (pr.isNotEmpty) sb.write('<w:rPr>$pr</w:rPr>');
      if (i > 0) sb.write('<w:br/>');
      final segs = parts[i].split('\t');
      for (var k = 0; k < segs.length; k++) {
        if (k > 0) sb.write('<w:tab/>');
        if (segs[k].isNotEmpty) sb.write('<w:t xml:space="preserve">${xmlEscape(segs[k])}</w:t>');
      }
      sb.write('</w:r>');
    }
    if (r.link != null && r.link!.isNotEmpty) {
      final id = rels.add(relHyperlink, r.link!, external: true);
      return '<w:hyperlink r:id="$id">$sb</w:hyperlink>';
    }
    return sb.toString();
  }

  String paraXml(DocParagraph p, {String? sectPr}) {
    final pr = StringBuffer();
    final style = switch (p.style) {
      ParaStyle.title => 'Title',
      ParaStyle.h1 => 'Heading1',
      ParaStyle.h2 => 'Heading2',
      ParaStyle.h3 => 'Heading3',
      ParaStyle.bullet || ParaStyle.numbered => 'ListParagraph',
      _ => null,
    };
    if (style != null) pr.write('<w:pStyle w:val="$style"/>');
    if (p.style == ParaStyle.bullet || p.style == ParaStyle.numbered) {
      pr.write('<w:numPr><w:ilvl w:val="${p.listLevel.clamp(0, 8)}"/><w:numId w:val="${p.style == ParaStyle.bullet ? 1 : 2}"/></w:numPr>');
    }
    pr.write('<w:spacing w:before="${_tw(p.spaceBefore)}" w:after="${p.style == ParaStyle.normal && p.spaceBefore == 0 ? 120 : 0}"/>');
    if (p.indentLeft > 0) pr.write('<w:ind w:left="${_tw(p.indentLeft)}"/>');
    final jc = switch (p.align) { ParaAlign.center => 'center', ParaAlign.right => 'right', ParaAlign.justify => 'both', _ => null };
    if (jc != null) pr.write('<w:jc w:val="$jc"/>');
    if (sectPr != null) pr.write(sectPr);
    return '<w:p><w:pPr>$pr</w:pPr>${p.runs.map(runXml).join()}</w:p>';
  }

  String imageXml(DocImage img) {
    imageNo++;
    final ext = img.isJpeg ? 'jpeg' : 'png';
    final path = 'media/image$imageNo.$ext';
    opc.addBinary('word/$path', img.bytes);
    final rid = rels.add(relImage, path);
    final cx = _emu(img.width), cy = _emu(img.height);
    final id = docPr++;
    final graphic = '<a:graphic xmlns:a="$_a"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="$_pic"><pic:nvPicPr><pic:cNvPr id="$id" name="Picture $id"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic>';
    if (img.x != null && img.y != null) {
      return '<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="${251658240 + id}" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1">'
          '<wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>${_emu(img.x!)}</wp:posOffset></wp:positionH>'
          '<wp:positionV relativeFrom="page"><wp:posOffset>${_emu(img.y!)}</wp:posOffset></wp:positionV>'
          '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/><wp:docPr id="$id" name="Picture $id"/>'
          '<wp:cNvGraphicFramePr/>$graphic</wp:anchor></w:drawing></w:r>';
    }
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$cx" cy="$cy"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="$id" name="Picture $id"/><wp:cNvGraphicFramePr/>$graphic</wp:inline></w:drawing></w:r>';
  }

  String tableXml(DocTable t, double contentWidth) {
    final cols = math.max(1, t.columnCount);
    final widths = t.columnWidths != null && t.columnWidths!.length == cols
        ? t.columnWidths!.map((w) => w * contentWidth / t.columnWidths!.fold<double>(0, (a, b) => a + b)).toList()
        : List<double>.filled(cols, contentWidth / cols);
    final sb = StringBuffer('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="${_tw(contentWidth)}" w:type="dxa"/>'
        '<w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:left w:val="single" w:sz="4" w:space="0" w:color="808080"/>'
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:right w:val="single" w:sz="4" w:space="0" w:color="808080"/>'
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="808080"/></w:tblBorders>'
        '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr><w:tblGrid>');
    for (final w in widths) {
      sb.write('<w:gridCol w:w="${_tw(w)}"/>');
    }
    sb.write('</w:tblGrid>');
    for (var ri = 0; ri < t.rows.length; ri++) {
      final row = t.rows[ri];
      sb.write('<w:tr>${ri == 0 && t.headerRow ? '<w:trPr><w:tblHeader/></w:trPr>' : ''}');
      for (var c = 0; c < cols; c++) {
        final cell = c < row.length ? row[c] : const DocTableCell('');
        final bold = cell.bold || (ri == 0 && t.headerRow);
        sb.write('<w:tc><w:tcPr><w:tcW w:w="${_tw(widths[c])}" w:type="dxa"/></w:tcPr><w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>');
        if (cell.text.isNotEmpty) sb.write(runXml(DocRun(cell.text, bold: bold)));
        sb.write('</w:p></w:tc>');
      }
      sb.write('</w:tr>');
    }
    sb.write('</w:tbl><w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr></w:p>');
    return sb.toString();
  }

  final contentWidth = m.pageWidth - 2 * m.margin;
  for (var i = 0; i < m.blocks.length; i++) {
    final b = m.blocks[i];
    switch (b) {
      case DocParagraph p:
        body.write(paraXml(p));
      case DocImage img:
        body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>${imageXml(img)}</w:p>');
      case DocTable t:
        if (t.rows.isNotEmpty) body.write(tableXml(t, contentWidth));
      case DocPageBreak br:
        if (br.pageWidth != null && br.pageHeight != null) {
          // A section per page keeps each page's size.
          body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0"/>${sect(br.pageWidth!, br.pageHeight!)}</w:pPr></w:p>');
        } else {
          body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        }
    }
  }
  final doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="$_w" xmlns:r="$_r" xmlns:wp="$_wp" xmlns:a="$_a" xmlns:pic="$_pic"><w:body>$body${sect(m.pageWidth, m.pageHeight, last: true)}</w:body></w:document>';
  opc.addXml('word/document.xml', doc, contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml');
  opc.addXml('word/styles.xml', _styles, contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml');
  opc.addXml('word/numbering.xml', _numbering, contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml');
  opc.addXml('word/settings.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings xmlns:w="$_w"><w:defaultTabStop w:val="720"/></w:settings>',
      contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml');
  opc.addXml('word/_rels/document.xml.rels', rels.xml());
  final root = Rels()
    ..add(relOfficeDoc, 'word/document.xml')
    ..add(relCore, 'docProps/core.xml')
    ..add(relApp, 'docProps/app.xml');
  opc.addXml('_rels/.rels', root.xml());
  opc.addXml('docProps/core.xml', corePropsXml(m.title), contentType: 'application/vnd.openxmlformats-package.core-properties+xml');
  opc.addXml('docProps/app.xml', appPropsXml(), contentType: 'application/vnd.openxmlformats-officedocument.extended-properties+xml');
  return opc.finish();
}

String _hdrFtr(String tag, String text) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:$tag xmlns:w="$_w" xmlns:r="$_r">${text.split('\n').map((l) => '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:sz w:val="18"/></w:rPr><w:t xml:space="preserve">${xmlEscape(l)}</w:t></w:r></w:p>').join()}</w:$tag>';

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="$_w">'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
    '<w:pPr><w:spacing w:after="240"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
    '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
    '<w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
    '<w:pPr><w:keepNext/><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>'
    '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
    '</w:styles>';

final String _numbering = () {
  String lvls(bool bullet) {
    final sb = StringBuffer();
    const bullets = ['•', '◦', '▪'];
    for (var i = 0; i < 9; i++) {
      sb.write('<w:lvl w:ilvl="$i"><w:start w:val="1"/><w:numFmt w:val="${bullet ? 'bullet' : 'decimal'}"/>'
          '<w:lvlText w:val="${bullet ? bullets[i % 3] : '%${i + 1}.'}"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="${720 * (i + 1)}" w:hanging="360"/></w:pPr></w:lvl>');
    }
    return sb.toString();
  }

  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="$_w">'
      '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>${lvls(true)}</w:abstractNum>'
      '<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>${lvls(false)}</w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>';
}();

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// Reads a DOCX into a [DocModel]: paragraphs with run formatting, headings,
/// lists, tables, images, page breaks, header/footer text and page size.
DocModel readDocx(Uint8List bytes) {
  final opc = OpcReader(bytes);
  var main = 'word/document.xml';
  final root = opc.rels('');
  for (final r in root.values) {
    if (r.$1.endsWith('/officeDocument')) main = r.$2;
  }
  final doc = opc.xml(main);
  if (doc == null) throw const FormatException('This DOCX has no document body.');
  final rels = opc.rels(main);
  // Style sizes and heading levels.
  final styleInfo = <String, (ParaStyle, double?, bool)>{};
  final styles = opc.xml('word/styles.xml');
  if (styles != null) {
    for (final s in styles.rootElement.all('style')) {
      final id = s.attr('styleId') ?? '';
      final name = (s.kid('name')?.attr('val') ?? id).toLowerCase();
      final sz = s.all('sz').firstOrNull?.attr('val');
      final bold = s.all('b').isNotEmpty;
      final lvl = s.all('outlineLvl').firstOrNull?.attr('val');
      var st = ParaStyle.normal;
      if (name.startsWith('list bullet')) {
        st = ParaStyle.bullet;
      } else if (name.startsWith('list number')) {
        st = ParaStyle.numbered;
      } else if (name == 'title') {
        st = ParaStyle.title;
      } else if (name.startsWith('heading 1') || lvl == '0') {
        st = ParaStyle.h1;
      } else if (name.startsWith('heading 2') || lvl == '1') {
        st = ParaStyle.h2;
      } else if (name.startsWith('heading') || lvl == '2') {
        st = ParaStyle.h3;
      }
      styleInfo[id] = (st, sz == null ? null : (double.tryParse(sz) ?? 22) / 2, bold);
    }
  }
  // Numbering formats: numId → bullet?
  final bulletNum = <String, bool>{};
  final numbering = opc.xml('word/numbering.xml');
  if (numbering != null) {
    final abs = <String, bool>{};
    for (final a in numbering.rootElement.kids('abstractNum')) {
      final fmt = a.all('numFmt').firstOrNull?.attr('val') ?? 'bullet';
      abs[a.attr('abstractNumId') ?? ''] = fmt == 'bullet';
    }
    for (final n in numbering.rootElement.kids('num')) {
      bulletNum[n.attr('numId') ?? ''] = abs[n.kid('abstractNumId')?.attr('val') ?? ''] ?? true;
    }
  }

  final blocks = <DocBlock>[];
  double pageW = 595.28, pageH = 841.89, margin = 54;

  Uint8List? imageFor(XmlElement drawing) {
    final blip = drawing.all('blip').firstOrNull;
    final id = blip?.attr('embed');
    if (id == null) return null;
    final rel = rels[id];
    return rel == null ? null : opc.bytes(rel.$2);
  }

  (double, double) extentOf(XmlElement drawing) {
    final ext = drawing.all('extent').firstOrNull;
    final cx = double.tryParse(ext?.attr('cx') ?? '') ?? 0;
    final cy = double.tryParse(ext?.attr('cy') ?? '') ?? 0;
    return (cx / 12700, cy / 12700);
  }

  void paragraph(XmlElement p, List<DocBlock> out) {
    final pPr = p.kid('pPr');
    final styleId = pPr?.kid('pStyle')?.attr('val');
    final info = styleId == null ? null : styleInfo[styleId];
    var style = info?.$1 ?? ParaStyle.normal;
    final numPr = pPr?.kid('numPr');
    var level = 0;
    if (numPr != null) {
      final numId = numPr.kid('numId')?.attr('val') ?? '';
      if (numId != '0') {
        style = (bulletNum[numId] ?? true) ? ParaStyle.bullet : ParaStyle.numbered;
        level = int.tryParse(numPr.kid('ilvl')?.attr('val') ?? '0') ?? 0;
      }
    }
    final align = switch (pPr?.kid('jc')?.attr('val')) {
      'center' => ParaAlign.center,
      'right' || 'end' => ParaAlign.right,
      'both' || 'distribute' => ParaAlign.justify,
      _ => ParaAlign.left,
    };
    final indent = (double.tryParse(pPr?.kid('ind')?.attr('left') ?? pPr?.kid('ind')?.attr('start') ?? '') ?? 0) / 20;
    final runs = <DocRun>[];
    void runsIn(XmlElement el, {String? link}) {
      for (final c in el.childElements) {
        switch (c.local) {
          case 'r':
            final rPr = c.kid('rPr');
            bool on(String tag) {
              final e = rPr?.kid(tag);
              if (e == null) return false;
              final v = e.attr('val');
              return v == null || (v != '0' && v != 'false' && v != 'none');
            }

            final sz = rPr?.kid('sz')?.attr('val');
            final col = rPr?.kid('color')?.attr('val');
            final font = rPr?.kid('rFonts')?.attr('ascii') ?? rPr?.kid('rFonts')?.attr('hAnsi');
            final bold = on('b') || (info?.$3 ?? false);
            final size = sz != null ? (double.tryParse(sz) ?? 22) / 2 : info?.$2;
            final colour = col != null && col != 'auto' ? (0xFF000000 | (int.tryParse(col, radix: 16) ?? 0)) : null;
            final sb = StringBuffer();
            void flush() {
              if (sb.isNotEmpty) {
                runs.add(DocRun(sb.toString(), bold: bold, italic: on('i'), underline: on('u'), size: size, color: colour, font: font, link: link));
                sb.clear();
              }
            }

            for (final t in c.childElements) {
              switch (t.local) {
                case 't':
                  sb.write(t.innerText);
                case 'tab':
                  sb.write('\t');
                case 'br' || 'cr':
                  if (t.attr('type') == 'page') {
                    flush();
                    runs.add(const DocRun('\f'));
                  } else {
                    sb.write('\n');
                  }
                case 'drawing' || 'pict':
                  flush();
                  final data = imageFor(t);
                  if (data != null) {
                    final (w, h) = extentOf(t);
                    out.add(DocImage(data, w > 0 ? w : 200, h > 0 ? h : 150));
                  }
              }
            }
            flush();
          case 'hyperlink':
            final id = c.rid;
            runsIn(c, link: id == null ? null : rels[id]?.$2);
          case 'smartTag' || 'sdt' || 'sdtContent' || 'ins' || 'fldSimple':
            runsIn(c, link: link);
        }
      }
    }

    final before = out.length;
    runsIn(p);
    // Split on page breaks.
    final para = <DocRun>[];
    final para2 = <DocBlock>[];
    for (final r in runs) {
      if (r.text == '\f') {
        para2.add(DocParagraph([...para], style: style, align: align, indentLeft: indent, listLevel: level));
        para.clear();
        para2.add(const DocPageBreak());
      } else {
        para.add(r);
      }
    }
    para2.add(DocParagraph(para, style: style, align: align, indentLeft: indent, listLevel: level));
    out.insertAll(before, para2.where((b) => b is! DocParagraph || !b.isEmpty || b.runs.isEmpty));
    if (pPr?.kid('sectPr') != null) out.add(const DocPageBreak());
  }

  void table(XmlElement tbl, List<DocBlock> out) {
    final rows = <List<DocTableCell>>[];
    for (final tr in tbl.kids('tr')) {
      final cells = <DocTableCell>[];
      for (final tc in tr.kids('tc')) {
        final text = tc.kids('p').map((p) => p.all('t').map((t) => t.innerText).join()).join('\n');
        final bold = tc.all('b').isNotEmpty;
        final span = int.tryParse(tc.kid('tcPr')?.kid('gridSpan')?.attr('val') ?? '1') ?? 1;
        cells.add(DocTableCell(text, bold: bold));
        for (var i = 1; i < span; i++) {
          cells.add(const DocTableCell(''));
        }
      }
      rows.add(cells);
    }
    final header = tbl.kids('tr').firstOrNull?.kid('trPr')?.kid('tblHeader') != null;
    out.add(DocTable(rows, headerRow: header));
  }

  final body = doc.rootElement.kid('body');
  if (body != null) {
    void walk(XmlElement el) {
      for (final c in el.childElements) {
        switch (c.local) {
          case 'p':
            paragraph(c, blocks);
          case 'tbl':
            table(c, blocks);
          case 'sdt' || 'sdtContent' || 'customXml':
            walk(c);
          case 'sectPr':
            final sz = c.kid('pgSz');
            pageW = (double.tryParse(sz?.attr('w') ?? '') ?? 11906) / 20;
            pageH = (double.tryParse(sz?.attr('h') ?? '') ?? 16838) / 20;
            margin = (double.tryParse(c.kid('pgMar')?.attr('left') ?? '') ?? 1080) / 20;
        }
      }
    }

    walk(body);
  }
  String partText(String type) {
    for (final r in rels.values) {
      if (r.$1.endsWith('/$type')) {
        final x = opc.xml(r.$2);
        if (x != null) return x.rootElement.all('p').map((p) => p.all('t').map((t) => t.innerText).join()).where((s) => s.trim().isNotEmpty).join('\n');
      }
    }
    return '';
  }

  if (blocks.isNotEmpty && blocks.last is DocPageBreak) blocks.removeLast();
  final title = opc.xml('docProps/core.xml')?.rootElement.all('title').firstOrNull?.innerText ?? '';
  return DocModel(blocks,
      header: partText('header'),
      footer: partText('footer'),
      pageWidth: pageW,
      pageHeight: pageH,
      margin: margin.clamp(18, 144).toDouble(),
      title: title);
}

/// Default paragraph size for a style when runs carry none.
double defaultSizeFor(ParaStyle s, {double base = 11}) => switch (s) {
      ParaStyle.title => 24,
      ParaStyle.h1 => 16,
      ParaStyle.h2 => 14,
      ParaStyle.h3 => 12,
      _ => base,
    };
