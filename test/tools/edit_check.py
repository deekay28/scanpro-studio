#!/usr/bin/env python3
"""Editability check for a DOCX rebuilt from the mess bill (or any page).

Usage: python3 -I test/tools/edit_check.py IN.docx OUT_DIR

Edits the document the way a person would in Word, with python-docx (an
independent implementation, not the app's code), saves it, reopens it and
checks that each edit took and nothing else moved:

1. change the bill title (a paragraph or band cell), without touching any image;
2. change a bill detail ("Maj" -> "Col");
3. change the amount in its table cell;
4. move the QR code (its anchor position);
5. replace the seal image with another picture;
6. edit a payment-note paragraph;
7. save, reopen: edits present, same number of pictures, tables and pages.

If LibreOffice is installed the edited file is also rendered to PDF and the
page count and edited text are checked there. Prints a JSON report.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

from docx import Document
from docx.oxml.ns import qn
from PIL import Image

W = qn('w:t')


def all_paragraphs(doc):
    for p in doc.paragraphs:
        yield p
    for t in doc.tables:
        for row in t.rows:
            for c in row.cells:
                for p in c.paragraphs:
                    yield p


def full_text(doc):
    return '\n'.join(p.text for p in all_paragraphs(doc))


def anchors(doc):
    return doc.element.body.findall('.//' + qn('wp:anchor'))


def descr(a):
    return a.find(qn('wp:docPr')).get('descr')


def set_paragraph_text(p, text):
    runs = p.runs
    runs[0].text = text
    for r in runs[1:]:
        r.text = ''


def main():
    src, out_dir = sys.argv[1:3]
    os.makedirs(out_dir, exist_ok=True)
    doc = Document(src)
    before_media = len(doc.inline_shapes) + len(anchors(doc))
    before_tables = len(doc.tables)
    report = {'checks': {}}

    def check(name, ok, detail=''):
        report['checks'][name] = {'ok': bool(ok), 'detail': detail}

    # 1. Title.
    title = next((p for p in all_paragraphs(doc) if 'HEADQUARTERS' in p.text.upper() and 'BILL' in p.text.upper()), None)
    check('1 title found as text', title is not None, title.text if title else '')
    if title is not None:
        set_paragraph_text(title, 'HEADQUARTERS OFFICERS MESS BILL (EDITED)')
    # 2. Bill detail.
    maj = next((r for p in all_paragraphs(doc) for r in p.runs if r.text.strip() == 'Maj'), None)
    check('2 bill detail is a run', maj is not None)
    if maj is not None:
        maj.text = 'Col'
    # 3. Amount cell.
    cell = None
    for t in doc.tables:
        for row in t.rows:
            for c in row.cells:
                if c.text.strip() == '99,491.00' and cell is None:
                    cell = c
    check('3 amount is a table cell', cell is not None)
    if cell is not None:
        set_paragraph_text(cell.paragraphs[0], '1,00,000.00')
    # 4. Move the QR code.
    qr = next((a for a in anchors(doc) if descr(a) == 'QR code'), None)
    check('4 QR code is a separate picture', qr is not None)
    qr_x = None
    if qr is not None:
        off = qr.find(qn('wp:positionH')).find(qn('wp:posOffset'))
        qr_x = int(off.text) + 50 * 12700
        off.text = str(qr_x)
    # 5. Replace the seal image.
    seal = next((a for a in anchors(doc) if descr(a) in ('Stamp or seal', 'Graphic')), None)
    check('5 seal is a separate picture', seal is not None)
    new_png = io.BytesIO()
    Image.new('RGB', (40, 40), (200, 0, 0)).save(new_png, 'PNG')
    if seal is not None:
        rid = seal.find('.//' + qn('a:blip')).get(qn('r:embed'))
        part = doc.part.related_parts[rid]
        part._blob = new_png.getvalue()
    # 6. Note paragraph.
    note = next((p for p in all_paragraphs(doc) if 'Payment also made' in p.text), None)
    check('6 note is a paragraph', note is not None, note.text if note else '')
    if note is not None:
        for r in note.runs:
            if r.text == 'also':
                r.text = 'can also be'
                break
    # 7. Save and reopen.
    edited = os.path.join(out_dir, 'edited.docx')
    doc.save(edited)
    d2 = Document(edited)
    text = full_text(d2)
    check('7a edits kept after reopening', all(s in text for s in ['(EDITED)', 'Col', '1,00,000.00', 'can also be']), '')
    check('7b same pictures and tables', len(anchors(d2)) + len(d2.inline_shapes) == before_media and len(d2.tables) == before_tables,
          f'{len(anchors(d2))} pictures, {len(d2.tables)} tables')
    if qr_x is not None:
        q2 = next(a for a in anchors(d2) if descr(a) == 'QR code')
        check('7c QR moved', int(q2.find(qn('wp:positionH')).find(qn('wp:posOffset')).text) == qr_x)
    if seal is not None:
        s2 = next(a for a in anchors(d2) if descr(a) in ('Stamp or seal', 'Graphic'))
        rid = s2.find('.//' + qn('a:blip')).get(qn('r:embed'))
        check('7d seal replaced', d2.part.related_parts[rid].blob == new_png.getvalue())
    check('7e no full-page picture', not any(descr(a) == 'Page image' for a in anchors(d2)))
    if shutil.which('soffice'):
        tmp = tempfile.mkdtemp()
        env = {k: v for k, v in os.environ.items() if k != 'FONTCONFIG_FILE'}
        subprocess.run(['soffice', '--headless', f'-env:UserInstallation=file://{tmp}/p', '--convert-to', 'pdf', '--outdir', tmp, edited],
                       capture_output=True, env=env)
        pdf = os.path.join(tmp, 'edited.pdf')
        info = subprocess.run(['pdfinfo', pdf], capture_output=True, text=True).stdout
        pages = int(next(l.split()[-1] for l in info.splitlines() if l.startswith('Pages:')))
        txt = subprocess.run(['pdftotext', '-layout', pdf, '-'], capture_output=True, text=True).stdout
        shutil.copy(pdf, os.path.join(out_dir, 'edited_rendered.pdf'))
        check('7f renders on one page after editing', pages == 1, f'{pages} page(s)')
        check('7g edits visible when rendered', '(EDITED)' in txt and '1,00,000.00' in txt and 'can also be' in txt)
        shutil.rmtree(tmp, ignore_errors=True)
    report['passed'] = all(c['ok'] for c in report['checks'].values())
    print(json.dumps(report))


if __name__ == '__main__':
    main()
