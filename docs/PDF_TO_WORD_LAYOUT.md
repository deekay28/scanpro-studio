# PDF → Word: layout-preserving conversion

This page covers the diagnosis of the layout bug, the three conversion modes, the processing stages, the regression case and its measured results, and the known limits.

## 1. Diagnosis (why the old output looked wrong)

The regression case is a photographed one-page bill: `test/fixtures/mess_bill/source.pdf` (a 1080×1440 JPEG on an A4 page). The bad output the app produced is `previous_output.docx`. The old converter:

- **Threw the page image away.** The page had no text layer, so it went through OCR, and only the recognised text was kept. The QR code, the seal, the stamp and the signature were never extracted, so the DOCX had **0 pictures**.
- **Rebuilt the page as flowing paragraphs.** OCR lines were grouped into paragraphs by vertical gaps and written with default spacing. Word re-flowed them, so every position was lost, including:
  - centred headings;
  - the two-sided "Month : Oct-26" lines;
  - the right-aligned amounts;
  - the notes.
- **Guessed tables only from text alignment.** The ruled charges table was not detected from its lines. Merged cells, borders, the shaded heading band and the total row were lost.
- **Ignored the photo's geometry.** OCR ran on the tilted, perspective-distorted photo, so line and column grouping was unstable.
- **Used no font metrics.** Sizes came from box heights, so text widths did not match the original.

Measured on the old output (`report/before_report.md`, rendered with LibreOffice and compared with the source):

| Measure | Value |
|---|---|
| SSIM | 0.54 |
| Median word displacement | **89 pt** |
| 90th percentile displacement | 212 pt |
| Pictures | 0 |
| OCR word recall | 0.87 |

## 2. Modes

The choice is under **Conversion Centre → PDF → Word**. Each option shows an explanation.

| Mode | What you get | Editable? |
|---|---|---|
| **Faithful layout** | One page-sized picture per page, placed behind an empty paragraph, in a Word section with the source page's exact size and orientation. When the page is a single upright JPEG (a typical scan), the **original JPEG bytes** are embedded unchanged. Otherwise the page is rendered at the chosen resolution (default 300 dpi, 150–400 under *Advanced*) as JPEG at the chosen quality. | No. The result says so. |
| **Editable document** | Digital pages are rebuilt from the PDF's own text, fonts, sizes, colours, ruling lines and images. Scanned pages go through the scan pipeline below. Text is real Word text in paragraphs and tables at the original positions. Seals, stamps, signatures, QR codes and logos are pictures anchored where they were. | Yes. |
| **Automatic** (default) | Per page: scanned pages use Faithful, digital pages use Editable. The result lists what was chosen ("1 page(s) were kept as page images (Automatic: scanned pages)…", "N digital page(s) rebuilt…"). | Digital pages only |

Other options:
- **Highlight uncertain words** (default on) highlights words that OCR read with low confidence, so they can be checked. Nothing is ever invented: an unreadable word is left as OCR read it and highlighted.
- The existing preview before saving still applies.

## 3. Stages

```
PDF page ─┬─ digital ─► nativeLayout ─────────────────────────────────┐
          │   words + fonts (PDFium), ruling lines → findGrids,       │
          │   images, underlines from rules                           │
          │                                                           ▼
          ├─ scanned ─► pageImage / renderOriginal ─► prepareScan ─► OCR ─► buildScanLayout ─► second OCR pass ─► LayoutPage ─► writeLayoutDocx
          │                                                                (missed regions)
          └─ faithful ─► pageImage (original JPEG or 300 dpi render) ────────────────────────► LayoutPage(background)
```

Code: `lib/features/convert/layout/`, wired up in `ConversionService._pdfToDocx`. Heavy steps run in background isolates.

1. **Page image** (`PdfiumSession.pageImage`). Returns the page's original JPEG when the page is just one upright image (letterboxed is fine); otherwise it renders the page.
2. **Scan preparation** (`prepareScan`):
   - `findPaperQuad` floods the dark background from the border, fits a line robustly to the middle of each paper edge, and intersects the lines to get the corners;
   - a homography warp straightens the paper.

   This rectified copy is used **only for analysis**. Pictures are cropped from it, but the output never contains a "corrected" version of the text.
3. **OCR** (ML Kit on the device; `recognizeWords` returns per-word boxes and confidence).
4. **Scan analysis** (`buildScanLayout`):
   - **Masks**: illumination-normalised ink, coloured ink, faint stroke-like ink (for pale seals), and outside-the-paper areas.
   - **Ruling lines**: traced with drift tolerance (photographed lines are slightly tilted), with short breaks joined.
   - **Words**: OCR border artefacts (`[`, `|`) are stripped and boxes are trimmed to the ink. A word's size is fitted from its ink width using real font metrics (Liberation Sans/Serif = Arial/Times widths). Sizes are harmonised per line and page. Bold comes from relative stroke width, made consistent across a phrase. Underlines come from ink runs under the words.
   - **Tables** (`findGrids`, shared with digital pages): touching horizontal and vertical lines, clustered. A vertical line that would cut through a word or phrase is rejected, and so is a horizontal line that is only an underline. Missing borders become row and column spans. Cell shading is detected per cell against the paper colour.
   - **Shaded bands**: a heading band darker than the paper above and below it.
   - **Graphics**: faint-mask components that are not text, lines, bands or tables. Each is classified as QR code, stamp, signature or graphic, and cropped (QR binarised, stamps whitened, everything else as photographed).
   - **Missed text**: ink of text-line height that no OCR word covers is listed in `unread`. Those regions are OCR'd again, enlarged, in a second pass. This recovers table cells an OCR engine skipped as one empty block.
   - Everything is mapped back to page points through the inverse homography.
5. **DOCX writer** (`writeLayoutDocx`):
   - one Word section per source page with the same page size, 14 pt margins and no added pages;
   - paragraphs with exact line heights and spacing taken from the source baselines;
   - tab stops for two-sided lines;
   - first-line and hanging indents for wrapped notes;
   - letter spacing so each word has its source width;
   - matched gaps between words;
   - tables in fixed layout with exact row heights, `gridSpan`/`vMerge`, cell shading and alignment from the text position (amounts right-aligned);
   - the shaded band as a borderless shaded cell;
   - pictures as `wp:anchor` elements relative to the page, each with a description (e.g. "QR code").

Fonts are estimated (Arial or Times New Roman metrics). The app never claims an exact font match.

## 4. Regression case and visual comparison

`test/tools/visual_compare.py SOURCE.pdf OUTPUT.docx OUT_DIR LABEL` runs the comparison. It:
- renders the DOCX with LibreOffice and both PDFs with Poppler at 100 dpi;
- checks page count and size;
- computes SSIM and mean difference;
- writes a heatmap and a side-by-side image;
- runs OCR on both renders and measures how far each matched word moved, plus word recall and precision;
- counts the DOCX's pictures, runs and tables.

`test/layout_test.dart` runs it on every case when LibreOffice and tesseract are installed. Run it with `SCANPRO_REPORT_DIR=dir` to keep the outputs.

The outputs for the reference bill are committed in `test/fixtures/mess_bill/report/`:
- `messbill_faithful*`, `messbill_editable*` and `messbill_auto*` (DOCX, rendered PDF, side-by-side, heatmap, report);
- `before_*` for the old output;
- `test_c/` for the other tests.

### Results (LibreOffice 24.2 rendering, tesseract 5.3.4 standing in for ML Kit)

**Test A – mess bill, Faithful**:
- 1 page, A4, 1 picture;
- the embedded JPEG is **byte-identical** to the source image;
- SSIM 0.9994, mean difference 0.2/255;
- word displacement median 0.0 pt, max 3.3 pt; OCR recall 0.98.

The remaining difference is LibreOffice's resampling of the picture.

**Test B – mess bill, Editable**:
- 1 page, A4, no extra pages.
- Pictures: 3 (QR code, seal, stamp with signature).
- Tables: 2. The shaded heading band, and the charges table with:
  - 3 rows × 4 columns, including the narrow empty column in the header that the bill has;
  - the total label spanning 3 columns;
  - right-aligned amounts.
- All the wording and values the test checks are present.
- Word displacement: median **1.8 pt**, 90th percentile 5.4 pt.
- Recall 0.89, precision 0.93.
- SSIM 0.68. This is low by nature: the output is a clean white page, the source is a photo with shadows, so SSIM can't be compared with Test A.
- Largest displacements: the end of note line 2 ("through POS", 25–30 pt), "Note", and the "Mess ACCOMMODATION" band heading (12–14 pt).

The output is **not** pixel-identical to the photo and doesn't claim to be.

**Automatic, mess bill**: the page is kept as a page image and the result says why.

**Test C**:

| Case | Mode | Pages / sizes | Median / p90 displacement | SSIM | Notes |
|---|---|---|---|---|---|
| C1 digital 2-page report (headings, bullets, ruled table, image) | Editable | 2/2, match | p1 0.7 / 3.2 pt, p2 0.7 / 1.8 pt | 0.95 / 0.99 | Table, image and text kept |
| C1 same | Faithful | 2/2, match | 0.4 / 0.8 pt | 0.98 / 0.996 | |
| C2 report page rotated 3° on a dark desk (photo-like scan) | Editable | 1/1 | 3.3 / 7.6 pt | 0.74 | Text straightened. Table rebuilt only after the second OCR pass: the first pass returned the table as one empty block. Recall 0.75 |
| C2 mixed PDF (digital page + that scan) | Automatic | 2/2 | – | – | Scan page kept as a page image, digital page as text. Both are reported |
| C3 A4 portrait, A5 landscape, Letter | Editable | 3/3, sizes match | ≈1.1 / 1.4 pt | ≥0.99 | |
| C3 same | Faithful | 3/3, sizes match | ≈0.5 / 0.7 pt | ≥0.998 | |

## 5. Limitations

- **Bold on blurry photos.** Bold detection from stroke width is approximate; for example, the bill's "Total Amount (Rounded off)" row comes out regular weight.
- **Underlines missed.** Some underlines are not found when the underline touches the word's box (e.g. "Sr.").
- **OCR errors are kept, not corrected.** They are highlighted instead; on the bill: "1," for "1.", "Mess" for "MESS", "BillNo".
- **Paper curl.** Only a 4-corner perspective is corrected. Curled paper (the bottom of the bill) leaves a few words up to ~30 pt off.
- **Fonts on scans** are estimated as Arial (or Times for serif digital fonts). Word substitutes fonts that aren't installed.
- **Digital pages:**
  - hyperlinks and filled vector shapes are not rebuilt (ruled tables, underlines and images are);
  - pages placed inside form XObjects (e.g. merged with some tools) lose their ruling lines and images in Editable mode, though the text is kept.
- **OCR engine.** On the device ML Kit does the OCR, and tests use tesseract, so results on a phone will differ from the numbers above.
- **Validation runs locally only.** The LibreOffice comparison runs where LibreOffice is installed (locally). CI installs tesseract, so Tests A–C run there, but the visual comparison parts are skipped.
- **Complex tables.** Tables without ruling lines are written as tab-aligned lines, not Word tables.

No paid SDK was added. Everything runs offline on the device with the libraries already in the app (PDFium, ML Kit, `image`).
