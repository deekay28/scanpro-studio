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

## Edge cases
- Airplane mode: everything except Smart scan module download works.
- Storage nearly full: export shows "Not enough storage space".
- Very long document (100+ pages): scroll, export with Email preset.
- App lock: enable, background 40 s, return → locked. Vault: move document in, restore it.
