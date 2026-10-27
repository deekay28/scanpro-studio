#!/usr/bin/env python3
"""Visual regression check for PDF -> DOCX conversion.

Usage: python3 -I test/tools/visual_compare.py SOURCE.pdf OUTPUT.docx OUT_DIR [LABEL]

1. Renders SOURCE.pdf with Poppler (pdftoppm) at a fixed resolution.
2. Renders OUTPUT.docx through LibreOffice (headless) to PDF, then to images
   at the same resolution.
3. Compares page count and page sizes, then each page:
   - structural similarity (SSIM, 8x8 windows on grayscale) and mean
     absolute difference,
   - a difference heatmap and a side-by-side image,
   - OCR (tesseract) on both renders: words found in both are matched by
     text and their displacement in points is measured (layout fidelity);
     word recall shows missing or invented text,
   - the number of embedded pictures in the DOCX.
4. Writes OUT_DIR/LABEL_report.json and OUT_DIR/LABEL_report.md.

No single number decides; the report lists all measurements and the
largest word displacements so differences can be inspected.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from collections import defaultdict

import numpy as np
from PIL import Image, ImageDraw

DPI = 100


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError(f'{cmd[0]} failed: {r.stderr}')
    return r.stdout


def page_sizes(pdf):
    out = run(['pdfinfo', '-f', '1', '-l', '999', pdf])
    sizes = []
    for m in re.finditer(r'Page\s+\d+ size:\s+([\d.]+) x ([\d.]+) pts', out):
        sizes.append((float(m.group(1)), float(m.group(2))))
    if not sizes:
        m = re.search(r'Page size:\s+([\d.]+) x ([\d.]+) pts', out)
        sizes.append((float(m.group(1)), float(m.group(2))))
    return sizes


def render(pdf, prefix):
    run(['pdftoppm', '-r', str(DPI), '-png', pdf, prefix])
    d = os.path.dirname(prefix)
    base = os.path.basename(prefix)
    files = sorted(f for f in os.listdir(d) if f.startswith(base + '-') and f.endswith('.png'))
    return [os.path.join(d, f) for f in files]


def gray(path, size=None):
    im = Image.open(path).convert('L')
    if size and im.size != size:
        im = im.resize(size, Image.BILINEAR)
    return np.asarray(im, dtype=np.float64)


def ssim(a, b, win=8):
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    h, w = (a.shape[0] // win) * win, (a.shape[1] // win) * win
    a, b = a[:h, :w], b[:h, :w]
    def blocks(x):
        return x.reshape(h // win, win, w // win, win).transpose(0, 2, 1, 3).reshape(-1, win * win)
    A, B = blocks(a), blocks(b)
    ma, mb = A.mean(1), B.mean(1)
    va, vb = A.var(1), B.var(1)
    cov = ((A - ma[:, None]) * (B - mb[:, None])).mean(1)
    s = ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma ** 2 + mb ** 2 + c1) * (va + vb + c2))
    return float(s.mean())


def ocr_words(png):
    out = run(['tesseract', png, 'stdout', '--psm', '3', 'tsv'])
    words = []
    for line in out.split('\n')[1:]:
        c = line.split('\t')
        if len(c) < 12 or c[0] != '5' or not c[11].strip():
            continue
        t = re.sub(r'[^\w₹.,:/&\'-]', '', c[11]).lower()
        if len(t) < 2 or float(c[10]) < 40:
            continue
        l, tp, w, h = map(float, c[6:10])
        k = 72 / DPI
        words.append((t, (l + w / 2) * k, (tp + h / 2) * k))
    return words


def match_words(src, out):
    """Pairs words with the same text (each used once), nearest first."""
    by = defaultdict(list)
    for t, x, y in out:
        by[t].append((x, y))
    pairs = []
    for t, x, y in src:
        cands = by.get(t)
        if not cands:
            continue
        j = min(range(len(cands)), key=lambda i: (cands[i][0] - x) ** 2 + (cands[i][1] - y) ** 2)
        ox, oy = cands.pop(j)
        pairs.append((t, x, y, ox, oy, ((ox - x) ** 2 + (oy - y) ** 2) ** 0.5))
    return pairs


def docx_pictures(docx):
    with zipfile.ZipFile(docx) as z:
        media = [n for n in z.namelist() if n.startswith('word/media/')]
        doc = z.read('word/document.xml').decode('utf8')
    return len(media), len(re.findall(r'<w:t[ >]', doc)), len(re.findall(r'<w:tbl>', doc))


def main():
    src_pdf, docx, out_dir = sys.argv[1:4]
    label = sys.argv[4] if len(sys.argv) > 4 else os.path.splitext(os.path.basename(docx))[0]
    os.makedirs(out_dir, exist_ok=True)
    tmp = tempfile.mkdtemp()
    try:
        shutil.copy(docx, os.path.join(tmp, 'out.docx'))
        run(['soffice', '--headless', f'-env:UserInstallation=file://{tmp}/profile', '--convert-to', 'pdf', '--outdir', tmp, os.path.join(tmp, 'out.docx')])
        out_pdf = os.path.join(tmp, 'out.pdf')
        shutil.copy(out_pdf, os.path.join(out_dir, f'{label}_rendered.pdf'))
        src_sizes, out_sizes = page_sizes(src_pdf), page_sizes(out_pdf)
        src_pages = render(src_pdf, os.path.join(tmp, 'src'))
        out_pages = render(out_pdf, os.path.join(tmp, 'out'))
        pics, text_runs, tables = docx_pictures(docx)
        report = {
            'label': label,
            'source_pages': len(src_pages), 'output_pages': len(out_pages),
            'source_sizes_pt': src_sizes, 'output_sizes_pt': out_sizes,
            'page_count_match': len(src_pages) == len(out_pages),
            'page_size_match': len(src_sizes) == len(out_sizes) and all(abs(a[0] - b[0]) < 1.5 and abs(a[1] - b[1]) < 1.5 for a, b in zip(src_sizes, out_sizes)),
            'docx_pictures': pics, 'docx_text_runs': text_runs, 'docx_tables': tables,
            'pages': [],
        }
        for i, (sp, op) in enumerate(zip(src_pages, out_pages)):
            a = gray(sp)
            b = gray(op, (a.shape[1], a.shape[0]))
            diff = np.abs(a - b)
            heat = np.zeros(a.shape + (3,), dtype=np.uint8)
            heat[..., 0] = np.clip(diff * 2, 0, 255)
            heat[..., 1] = (a * 0.35).astype(np.uint8)
            heat[..., 2] = (a * 0.35).astype(np.uint8)
            Image.fromarray(heat).save(os.path.join(out_dir, f'{label}_p{i + 1}_heatmap.png'))
            sa, sb = Image.open(sp).convert('RGB'), Image.open(op).convert('RGB').resize(Image.open(sp).size)
            side = Image.new('RGB', (sa.width * 2 + 20, sa.height), 'white')
            side.paste(sa, (0, 0))
            side.paste(sb, (sa.width + 20, 0))
            dr = ImageDraw.Draw(side)
            dr.text((10, 10), 'SOURCE', fill=(220, 0, 0))
            dr.text((sa.width + 30, 10), 'DOCX (LibreOffice)', fill=(220, 0, 0))
            sw, ow = ocr_words(sp), ocr_words(op)
            pairs = match_words(sw, ow)
            for t, x, y, ox, oy, d in pairs:
                k = DPI / 72
                if d > 6:
                    dr.line([(x * k, y * k), (ox * k + sa.width + 20, oy * k)], fill=(255, 140, 0), width=1)
            side.save(os.path.join(out_dir, f'{label}_p{i + 1}_side_by_side.png'))
            d = sorted(p[5] for p in pairs)
            src_set = [w[0] for w in sw]
            recall = len(pairs) / max(1, len(sw))
            precision = len(pairs) / max(1, len(ow))
            worst = sorted(pairs, key=lambda p: -p[5])[:8]
            report['pages'].append({
                'page': i + 1,
                'ssim': round(ssim(a, b), 4),
                'mean_abs_diff': round(float(diff.mean()), 2),
                'pixels_differing_over_64': round(float((diff > 64).mean()), 4),
                'ocr_words_source': len(sw), 'ocr_words_output': len(ow), 'matched_words': len(pairs),
                'word_recall': round(recall, 3), 'word_precision': round(precision, 3),
                'displacement_pt_median': round(d[len(d) // 2], 2) if d else None,
                'displacement_pt_p90': round(d[int(len(d) * 0.9)], 2) if d else None,
                'displacement_pt_max': round(d[-1], 2) if d else None,
                'largest_displacements': [{'word': p[0], 'source': [round(p[1]), round(p[2])], 'output': [round(p[3]), round(p[4])], 'pt': round(p[5], 1)} for p in worst],
            })
        with open(os.path.join(out_dir, f'{label}_report.json'), 'w') as f:
            json.dump(report, f, indent=2)
        md = [f'# Visual comparison: {label}', '',
              f'- Pages: source {report["source_pages"]}, output {report["output_pages"]} ({"match" if report["page_count_match"] else "MISMATCH"})',
              f'- Page sizes (pt): source {src_sizes}, output {out_sizes} ({"match" if report["page_size_match"] else "MISMATCH"})',
              f'- DOCX: {pics} picture(s), {text_runs} text run(s), {tables} table(s)', '']
        for p in report['pages']:
            md += [f'## Page {p["page"]}', '',
                   f'- SSIM {p["ssim"]}, mean absolute difference {p["mean_abs_diff"]}, pixels differing by >25%: {p["pixels_differing_over_64"] * 100:.1f}%',
                   f'- OCR words: source {p["ocr_words_source"]}, output {p["ocr_words_output"]}, matched {p["matched_words"]} (recall {p["word_recall"]}, precision {p["word_precision"]})',
                   f'- Word displacement (pt): median {p["displacement_pt_median"]}, 90th percentile {p["displacement_pt_p90"]}, max {p["displacement_pt_max"]}',
                   '- Largest displacements: ' + ', '.join(f'"{x["word"]}" {x["pt"]} pt' for x in p['largest_displacements']),
                   f'- Images: `{label}_p{p["page"]}_side_by_side.png`, `{label}_p{p["page"]}_heatmap.png`', '']
        with open(os.path.join(out_dir, f'{label}_report.md'), 'w') as f:
            f.write('\n'.join(md))
        print(json.dumps(report))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
