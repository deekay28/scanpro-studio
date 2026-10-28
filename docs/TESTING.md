# Manual device test checklist

Automated tests (`flutter test`) cover geometry, PDF operations, image processing, text analysis, the
database/search layer and backups. The items below need a real Android phone. Record each result as
**pass / fail / skipped** in `docs/BUILD_STATUS.md`.

## Workflow A – Scan paper to PDF
1. Home → Scan document (Smart scan). Capture 3 pages; confirm auto-capture and edge detection.
2. Review: reorder (drag handle), crop one page (corners + magnifier), delete one, undo.
3. Choose "Document Colour", tick OCR, Save. Accept a suggested name.
4. Document → Export PDF → A4, searchable, page numbers → Create → Preview → Save to device, Share, Print.
5. Open the saved PDF in another viewer; search for a word on page 1.

## Workflow A2 – Pro camera
- Permission prompt appears once; denying shows guidance and "Import photos instead".
- Live quad overlay follows a page on a dark table; turns green when steady; auto-capture fires once
  per page (moving the page re-arms it). Torch, tap-to-focus, exposure slider work.
- Kill the app mid-session → reopen → Home shows "Unfinished scan recovered" → Resume keeps page order.

## Workflow B – Gallery images to PDF
- Import 5 images including a HEIC and a very large photo; duplicates are flagged; auto crop applied.
- Edit page: filters, adjustments, compare side by side, Revert all, auto-straighten, auto-orient.
- Export PDF (Letter, landscape, fill, 10 mm margins) → reopen from Documents after restarting the app.

## Workflow C – Book
- Book scanner → capture 2 spreads → spine line shown → adjust spine → RTL toggle changes numbering →
  Create book → 4 pages in order; text near the spine visible on both pages.

## Workflow D – Passport photo
- ID Photo → India 35×45 → take photo → face auto-framed; guides visible; low-DPI warning appears for a
  small image. Background white + refine brush. 8 copies on A4 → 4×2 grid → PDF → print at 100% →
  measure: each photo 35 × 45 mm (±0.5 mm). 4×6 in landscape → 8 copies. PNG 600 dpi export.
- Print the calibration page and measure the 100 mm rulers.

## Workflow E – OCR
- English page and a Hindi page (Devanagari model) → flagged lines highlighted → correct a line →
  copy, TXT, CSV → searchable PDF → library search finds a Hindi word.

## Workflow F – Existing PDF
- Import a searchable PDF (text indexed → found by search), a password-protected PDF (prompt), and a
  damaged file (error message). Organise: reorder, rotate, delete, blank page → Save as new (original
  unchanged). Merge two PDFs, split "1-2, 3-", compress (lossless + Email), protect, remove password.

## Workflow G – PDF editor (see docs/PDF_EDITOR.md)
Use a typical office PDF (Word export), a PDF with a subset font, a scanned PDF, a Hindi PDF, a form
PDF and a password-protected PDF.
1. Documents → PDF → **Edit PDF**. Edit Text: tap a paragraph (blue outline) → tap again → fix a typo
   → **Check font & layout** says "Original font reused" → Apply. Compare (⇄) shows the original.
2. Make a sentence longer in a paragraph → it wraps inside the width; enable "Keep inside the original
   box" → font shrinks. Change colour/bold → the notice names the substitute font.
3. Drag a selected block and resize it with the right-edge handle; undo/redo both.
4. Add Text: tap a margin → type → Date quick action. Insert Image → Gallery → crop → resize with the
   corner handle (ratio kept) → rotate 15° → opacity 50%.
5. Sign → Draw → save → add name and date → move/resize. Sign → Import a photographed signature →
   background removed. Delete a saved signature.
6. Annotate: highlight two lines, underline, strike, pen, note, rectangle, arrow. Stamp → APPROVED with
   date; image stamp (seal photo, background removed).
7. Pages: reorder by drag, rotate, insert blank, delete, header/footer/page numbers/watermark, select 2
   pages → Extract.
8. Scanned PDF: banner "Scanned page" → Use OCR → Recognise (Hindi model for Hindi) → correct a line →
   Add as searchable layer → Replace a line visually → review on the page.
9. Kill the app while editing → reopen the same document → "Unsaved edits found" → Continue. Tools →
   Unfinished PDF edits lists drafts.
10. Save → "Save as new version" → the report shows pages checked, annotations kept, password kept. Open
   the new version in another PDF app: text is selectable/searchable; annotations are editable there;
   the original document is unchanged. Repeat with Flatten on (annotations burned in) and with
   Replace original (confirmation required).
11. Password PDF: wrong password is rejected; a PDF that forbids editing shows "Editing not allowed".
12. 300+ page PDF: page navigation and thumbnails stay responsive; saving completes.

## Workflow H – Conversion Centre (see docs/DOCUMENT_SUITE.md)
1. Tools → Conversion centre → PDF to Word → choose a 3-page office PDF → Editable document → Convert. The job
   screen shows progress, then Done with notes. Preview, then Share → open in Word / Google Docs: headings,
   table and image sit where they are in the PDF; same page count and size.
2. Photograph a printed bill (tilted, on a desk) → scan to PDF → PDF to Word:
   - Automatic: the notes say the page was kept as a page image; Word shows the photo, not editable.
   - Faithful layout: same, at the chosen resolution (Advanced).
   - Editable document: centred headings, shaded band, ruled table with right-aligned amounts, QR code /
     seal / signature as separate pictures in place, no highlights, no picture strips behind text. Compare
     side by side with the PDF. In Word: edit the title, a detail and the amount cell; move the QR code;
     replace the seal (Change Picture); save and reopen. File menu → Review OCR words: correct one word,
     Save, reopen the file. Turn OCR off: the page is kept as an image and the notes say so.
3. PDF to Excel with a bank statement → Review tables → merge two columns, delete one, fix a cell → Export
   XLSX → open in Excel/Sheets: numbers are numbers, flagged cells highlighted.
4. PDF to images: PNG, 300 dpi, pages "2-3", ZIP → estimated size shown → open the ZIP.
5. Select 5 PDFs for PDF to text → one job; cancel it midway → no partial files; Retry → done.
6. Start a large conversion, swipe the app away, reopen → job shows Interrupted → Retry.
7. Password PDF → asked for the password when chosen; wrong password re-asked.
8. Word/Excel/PowerPoint → PDF, PowerPoint → Excel (chart data sheet), Excel → PowerPoint (chart slide);
   open outputs in Microsoft Office apps and note anything that looks different.

## Workflow I – Reader, compare, forms, security
1. Any PDF → ⋮ More tools → Read: switch layouts, Dark, Sepia, a custom colour; thumbnails, contents,
   bookmark a page, search a word, Go to page, Copy text, Read aloud (speech starts, stops on tap).
   Close and reopen: it resumes at the same page; Recently read lists it.
2. Compare: original vs a version with an edited sentence and a changed amount → changes listed,
   highlighted on both sides, scrolling synchronised; export the report as PDF.
3. Fill form on a government form PDF → fill, sign the signature field → Save filled → open in another
   app: values present and still editable. Save flattened → not editable.
4. Create fillable form: add a text field, checkbox, dropdown and signature field → open elsewhere.
5. Links: add a web link and a page link; edit; remove; undo. Annotations: export XFDF, import into a
   copy, Flatten copy. Bookmarks: add, add nested, remove.
6. Headers, footers & watermark: page numbers on pages 2–end, date, logo watermark → Preview → Apply.
7. Redact: Find a name → marks on all pages → Redact → "Redaction verified" → open the copy in another
   app and search for the name: not found; select text under the black box: nothing.
8. Protect with permissions (printing only) → another app asks for the password; editing is blocked.
9. Compress: try Balanced and Email on a photo-heavy PDF → sizes shown → Use → text still selectable.
10. Page tools: insert 2 lined pages at the end, replace page 1 from another PDF, Repair.
11. Documents: long-press → Select → select all → Export as ZIP; sequential rename; duplicate; sort by size.

## Edge cases
- Airplane mode: everything except Smart scan module download works.
- Storage nearly full: export shows "Not enough storage space".
- Very long document (100+ pages): scroll, export with Email preset.
- App lock: enable, background 40 s, return → locked. Vault: move document in, restore it.
