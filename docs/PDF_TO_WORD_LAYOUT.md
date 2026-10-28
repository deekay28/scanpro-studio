# PDF → Word: layout-preserving, editable conversion

This page covers:
- why earlier outputs looked wrong;
- the three conversion modes;
- the processing stages and the rules that keep text and pictures apart;
- the OCR review;
- the regression cases and their measured results;
- the known limits.

The reference case is the photographed MCTE MHOW mess bill, kept in `test/fixtures/mess_bill/`:

| File | What it is |
|---|---|
| `source.pdf` | The photographed bill: a 1080×1440 JPEG on an A4 page |
| `source_image.jpg` | The embedded photo |
| `target_screenshot.jpg` | The target appearance |
| `previous_output.docx` | The first bad output |
| `phone_v1.0.10/` | What v1.0.10 produced on a phone: `editable.docx` and its LibreOffice render, and `page_image.docx` (Automatic/Faithful) |
| `report/` | The current outputs and every comparison image and report |

## 1. Diagnosis

### 1a. The first converter (`previous_output.docx`)

- **The page image was discarded.** Only OCR text was kept: no QR code, seal, stamp or signature, so the DOCX had 0 pictures.
- **Text was rebuilt as flowing paragraphs** with default spacing. Every position was lost: the median word was **89 pt** away from where it is on the bill.
- **Tables were guessed from text alignment**, not from the ruled lines, so borders, merged cells and the shaded band were lost.
- **OCR ran on the tilted photo**, with no perspective correction and no font metrics.

### 1b. v1.0.10 on a phone (`phone_v1.0.10/editable.docx`)

The fix for 1a passed every test here, but failed on the phone. The phone's DOCX has **6 pictures**. Two are wide strips cut from the photo:
- one across the contact line;
- one across the shaded band and the "Bill No / Month" line.

OCR text was then placed on top of the strips, so the content appears twice. Other symptoms:
- the stamp is split into pieces;
- its printed text was OCR'd into the document ("MESS SECRETARY", "oFFRS HESS MCTE");
- the "1" in the table is missing;
- there are yellow highlights.

**The root cause is OCR engine dependence.** The tests used tesseract, whose word boxes fit the ink tightly. The phone uses ML Kit, whose element boxes are looser, offset, and sometimes span two lines. Every later stage used the OCR boxes directly:
- shaded-band detection compared the paper above and below a word box;
- graphics detection treated any ink outside word boxes as a picture;
- line grouping used box overlap;
- font size used box width and height.

With ML Kit's boxes this went wrong in several ways:
- band detection failed;
- the band and nearby text ink became "graphics";
- lines merged;
- sizes blew up.

Reproduced here: tesseract words with ML Kit-like boxes (padded by 0.2–0.5 of their height, or whole lines split evenly into words) produced the same strips. With very loose boxes the page also overflowed to two pages, with oversized text and noise like "iy" placed as text.

### 1c. v1.0.11 on a phone (`phone_v1.0.11/editable.docx`)

The structure was right this time: no strips, 3 pictures, real tables. Three problems were left:
- **Missing colons.** ML Kit does not return lone punctuation. The ":" after Rank, Name, From, To and Date and the "/" in "'at par' / crossed" were missing, and "Fac/Wing:" came back as "FacWing:".
- **The lone "1"** in the table was not returned.
- **The grey band** started at the paper's shadowed left edge (10.8 pt) instead of the table/text column (43 pt).

Fixes:
- **Colons and slashes are read from the ink** when OCR leaves them out. A colon is two small dots stacked on the local baseline. A slash is a straight, narrow stroke rising to the right, standing alone or joined to the next letter (in which case that letter's ink is wider than it should be). Ink that OCR read as some other mark (for example ":" misread as "+") is not doubled. Recovered marks go into the review list.
- **Band edges** close to the table's or text column's edges (within 8% of the page width) are aligned with them.
- **The unread search** now accepts narrow marks and ignores broken cell-border pieces, so the "1" is sent to the second OCR pass. If it is still unreadable, the result notes say so, and Review OCR words lists it as an unread mark in a table cell. The cell is never silently emptied.

## 2. Modes

Choose under **Conversion Centre → PDF → Word**. Each option is explained on screen.

| Mode | What you get | Editable? |
|---|---|---|
| **Faithful layout** | One page-sized picture per page, at the exact page size and orientation. A single-JPEG scan keeps its original JPEG bytes; other pages are rendered at 300 dpi (150–400 under *Advanced*). | No. The result says so. |
| **Editable document** | Real Word paragraphs and tables at the original positions. Seals, stamps, signatures and QR codes are separate pictures. **There is never a page image or text strip behind the text.** | Yes |
| **Automatic** (default) | Scanned pages are Faithful and digital pages are Editable. The result says which was chosen for each page. | Digital pages |

Uncertain OCR words are **not highlighted** by default. Highlighting is an opt-in option ("Highlight uncertain words (review copy)"). See §4.

## 3. Stages (Editable document, scanned page)

Code: `lib/features/convert/layout/`, wired up in `ConversionService._pdfToDocx`.

1. **Page image**: the page's original JPEG, or a render.
2. **Preparation** (`prepareScan`, analysis only):
   - find the paper corners on the dark background;
   - apply a homography warp so the page is straight and flat;
   - normalise the lighting.

   Every element found later is mapped back through the same inverse homography and page rectangle, so text, tables and pictures share **one coordinate transform**.
3. **OCR**: ML Kit on the phone, with words, boxes, confidences and **the engine's line ids**.
4. **Ink geometry** (`InkGeometry`, new). OCR supplies the text and roughly where it is; the image supplies the geometry:
   - **remove long strokes**: horizontal and vertical runs longer than about 2.6 text heights (underlines, borders), so letters touching them separate;
   - **find letters**: connected ink components. Thin, tall pieces of short cell borders, isolated specks and hairlines are discarded;
   - **position words**: each word's position comes from the ink inside its box, and lines are the engine's own lines;
   - **assign ink to lines**: each component goes to the line of the nearest word, using that line's letter height;
   - **cut into words**: along each line, components that overlap horizontally form glyph clusters, and the words are cut at real gaps. A dynamic program picks the cuts that match OCR's boundaries, while strongly preferring wide gaps (a space is about 0.39 cap height in Arial; letter gaps are under 0.15);
   - **leave unread ink alone**: word-sized ink runs at the ends of a line that no OCR box reaches are left unassigned for the second OCR pass;
   - **drop non-text words**:
     - ink lighter or more coloured than the page's printed text (stamp text, the shadow at the paper edge);
     - words with no ink;
     - "words" several lines tall (noise on a signature or seal);
   - **resolve duplicates**: the same ink read twice keeps the more confident reading.
5. **Ruling lines**: traced in the ink outside the snapped words.
6. **Shaded bands**: a band is darker than the paper above and below it, measured beside the text.
7. **Tables** (`findGrids`):
   - grids are built from the ruling lines;
   - a vertical line that would cut a word is not a column border;
   - **a horizontal line that is just an underline of the words above it is not a row border**;
   - cells merge across missing borders.
8. **Graphics**: faint-ink components outside text, lines, bands and tables. **A candidate that contains whole words of printed text (8 or more letters or digits) is rejected: it is text, not a picture.** QR density is measured on the full ink, so module edges taken for lines still count. Classes:
   - QR code: dense and square; the crop is binarised;
   - stamp or seal: sparse line art; the crop is whitened, so paper becomes white and ink keeps its colour;
   - signature;
   - graphic.
9. **Second OCR pass**: text-height ink that no word covers (for example a table cell or a heading OCR skipped) is cropped. Each crop gets a white margin and is enlarged if small, then read again. Only confident words containing a letter or digit are taken. The layout is then rebuilt with all words.
10. **Typography**:
    - sizes are fitted from ink width with Arial/Times metrics; one- and two-character words are sized from their height;
    - bold comes from stroke width, decided per phrase by its average stroke;
    - underlines come from ink runs.
11. **Layout check** (`checkLayout`, new). Every page is checked for:
    - pictures covering text;
    - pictures overlapping each other;
    - text placed over a table;
    - lines reconstructed twice;
    - a full-page picture.

    Any finding is added to the result notes ("check the layout: …").
12. **DOCX** (`writeLayoutDocx`):
    - one section per page, same page size, 14 pt margins;
    - paragraphs with exact line heights and spacing from the source baselines;
    - tab stops for two-sided lines; **label/value blocks share aligned stops**, so labels, colons and values line up;
    - first-line/hanging indents and kept line breaks for notes;
    - fixed-layout Word tables with merges, borders, shading and alignment;
    - the band as a borderless shaded cell;
    - pictures anchored to the page with descriptions ("QR code", "Stamp or seal");
    - Devanagari runs use a complex-script font (Mangal) and are marked as Hindi.

Digital pages skip steps 2–10. Their text, fonts, ruling lines and images come from the PDF itself.

## 4. OCR review

- **In the document.** Words read with low confidence are written normally (no highlight). Each is wrapped in a hidden bookmark `_OCR_<n>`.
- **The review list.** A file `<name>.docx.review.json` is kept beside the output. For each uncertain word it records the page and position, the confidence and the line it was read in. It also lists words left out of the text (stamp text, noise).
- **Reviewing.** In the job's file menu, **Review OCR words** lists these words. The user corrects them and taps Save. Only those runs are rewritten (`applyOcrCorrections`); no other part of the document changes.
- **No automatic correction.** Names, dates and amounts are never corrected automatically. OCR's reading is kept until a person changes it.

## 5. Validation

Run `test/layout_test.dart`. Comparisons need LibreOffice and tesseract (plus zbar for the QR check). Set `SCANPRO_REPORT_DIR` to keep the outputs. The current outputs are committed in `test/fixtures/mess_bill/report/`.

### Tools

- `test/tools/visual_compare.py`:
  - renders the DOCX with LibreOffice and checks page count and size;
  - computes SSIM and writes a heatmap and a side-by-side image;
  - measures OCR word displacement and recall/precision;
  - counts pictures, runs and tables.
- `test/tools/edit_check.py` edits the DOCX with python-docx, an independent library:
  - changes the title, "Maj" → "Col", the amount cell and a note;
  - moves the QR code and replaces the seal image;
  - saves, reopens and re-renders, then checks that every edit took and that the page count and pictures are unchanged.

### Results (LibreOffice 24.2, tesseract 5.3.4)

**Mess bill, Editable** (`report/messbill_editable*`, and `messbill_source_target_new.png` for source vs target vs new):

| Check | Result |
|---|---|
| Pages | 1, A4 |
| Pictures | 3: QR code, seal, stamp with signature |
| Page image or strips behind text | None |
| Highlights | None |
| Tables | Shaded band; charges table of 3 rows × 4 columns (the bill's narrow empty column included). The total spans 3 columns and the amounts are right-aligned |
| Word displacement vs the photo | Median 2.2 pt, 90th percentile 5.6 pt |
| OCR word recall | 0.89 |
| QR code | Decodes to the same UPI payload as the photo (zbar) |
| Layout check | No findings |
| Review list | 5 uncertain words ("Mhow,", "Indore", "(M.P).", "Note", "Mess") |
| Coverage overlay | `messbill_editable_coverage.png` |

**The same bill with four OCR box styles** (`report/ocr_variants/`):

| Box style | Pictures (strips) | Tables | Median / p90 displacement | Recall |
|---|---|---|---|---|
| Tight (tesseract) | 3 (0) | 2 | 3.1 / 7.4 pt | 0.92 |
| Padded 0.2 h | 3 (0) | 2 | 2.9 / 6.5 pt | 0.92 |
| Padded 0.5 h | 3 (0) | 2 | 3.1 / 7.4 pt | 0.92 |
| Lines split evenly | 3 (0) | 2 | 2.6 / 12.0 pt | 0.86 |
| ML Kit as seen on the phone (padded boxes, no lone ":" "/" or "1", "FacWing:") | 3 (0) | 2 | 2.3 / 5.9 pt | 0.92 |

In every style, the test also requires:
- "Bill No :", "Rank :", "Name :", "Status :", "From :" and "Date :";
- "Fac/Wing" and "Credit /Debit";
- the band starting and ending with the charges table (within 1.5 pt).

For comparison, the v1.0.10 phone output had 6 pictures, 2 of them strips, and is kept as a failing fixture. In the line-split case the header words of the charges table can land one cell off; the test records this.

**Editability** (`report/edit_check/`): all 13 checks pass. The edited file renders on one page with every edit visible.

**Mess bill, Faithful**:
- the embedded JPEG is byte-identical to the source;
- SSIM 0.9994;
- word displacement 0.0 pt median.

**Other documents** (`report/test_c/`):

| Case | Result |
|---|---|
| Digital 2-page report | Editable: median 0.7 pt, table and image kept. Faithful: SSIM ≥ 0.98 |
| Scan rotated 3° on a desk | Editable: text straightened; the table rebuilt after the second OCR pass |
| Mixed digital + scanned PDF, Automatic | Page image for the scan, text for the digital page |
| A4, A5 landscape and Letter | Sizes and orientation kept in both modes |
| Hindi + English | Digital: Devanagari kept as text. Photographed form with the Hindi model: Devanagari and English rebuilt as text with aligned labels; tesseract dropped the "1" of "1,250.00" and it is not guessed |

All results come from rendering with LibreOffice. Microsoft Word may differ slightly, for example in font substitution and line spacing.

## 6. Limitations

- **ML Kit is not in these tests.** ML Kit runs only on a phone; the tests here use tesseract and tesseract-derived box styles to imitate it. The four box styles converge, but real ML Kit output wasn't tested directly.
- **Bold detection is approximate on photos.** For example, the bill's "Room Type" and total row come out regular weight.
- **Some OCR errors are kept** (and listed for review): "To + 17-Oct-2026" ("+" read for ":"), "BillNo", "1," for "1.", "Mess" for "MESS", and the missing colon after "Note".
- **Curled paper** is only perspective-corrected, so a few words end up up to ~25 pt off.
- **Fonts on scans** are estimated as Arial or Times. No exact font match is claimed.
- **Split boxes:** with evenly split line boxes, words in wide table rows can be assigned one cell off.
- **A lone digit ML Kit skips** (the "1" in the charges table) may stay unread. Tesseract can't read it from a crop either. The cell is then empty, and the notes and the review list say so.
- **Punctuation from ink:** only ":" and "/" are recovered from the ink. Other punctuation OCR drops (a lone "." or "-") is not recovered.
- **Digital pages:** hyperlinks and filled vector shapes are not rebuilt. Pages wrapped in form XObjects lose their ruling lines and images in Editable mode.
- **Complex tables:** tables without ruling lines become tab-aligned lines, not Word tables.
- **CI coverage:** CI has no LibreOffice, so the visual comparisons run locally only. Tesseract (English and Hindi) and zbar run in CI.

No paid SDK is used. Everything runs offline on the device.
