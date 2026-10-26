# PDF editor

The PDF editor edits the content of existing PDFs on the device: text, images, signatures, annotations, stamps and pages. It never changes the file you opened. Every edit is a recipe that's applied to an untouched copy of the original when you preview or save.

Open it from:
- **Documents → a PDF → Edit PDF**
- **PDF viewer → ✎ (Edit PDF)**
- **Documents → a scanned document → ⋮ → Edit as PDF**. This builds a searchable PDF from the scans first.
- **Tools → Edit PDF** (pick any PDF) and **Tools → Unfinished PDF edits** (recover drafts)

---

## 1. Engine choice

### What the app already had
`syncfusion_flutter_pdf` creates PDFs, merges and splits pages, encrypts files and extracts text with font name, size and style. **It can't edit existing content.** Its Flutter edition has no redaction, no access to page objects and no way to rewrite or remove existing text. It can only draw new content on top. It also has no ink, free-text or stamp annotations. Using it alone would have meant "covering" old text with white boxes, which isn't real editing. It's still used for the existing tools (merge, split, compress, protect), so those weren't rewritten.

### Options evaluated

| | **PDFium** (chosen) | Nutrient (formerly PSPDFKit) | Apryse (formerly PDFTron) | Syncfusion (existing) | MuPDF |
|---|---|---|---|---|---|
| True editing of existing text (rewrite/remove text objects) | ✅ page-object API (`FPDFText_SetText`, `FPDFPage_RemoveObject`, …) | ✅ Content Editor (paid add-on component) | ✅ Content editing (paid add-on) | ❌ add only | ✅ |
| Reuses embedded fonts | ✅ when the glyphs exist (checked per character) | ✅ | ✅ | ❌ | ✅ |
| Image edit / insert | ✅ | ✅ | ✅ | insert only | ✅ |
| Annotations (ink, markup, stamp, note, shapes) | ✅ with appearance streams | ✅ | ✅ | partial | ✅ |
| Handwritten signature image | ✅ | ✅ | ✅ | ✅ | ✅ |
| Cryptographic digital signatures | ❌ not in this app | ✅ (paid) | ✅ (paid) | ✅ | partial |
| Form filling | not implemented (forms are preserved) | ✅ | ✅ | ✅ | ✅ |
| Offline | ✅ | ✅ | ✅ | ✅ | ✅ |
| Android / future iOS | ✅ / ✅ (`pdfium_flutter` XCFramework) | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| Licence | **BSD-3-Clause + Apache-2.0, free** | Commercial, quote-based, licence key required | Commercial, quote-based, licence key required | Commercial ([community licence](https://www.syncfusion.com/products/communitylicense) free for small organisations) | **AGPL-3.0** or commercial |
| Builds without a key or account | ✅ | ❌ (trial adds watermarks; production needs a key) | ❌ (same) | ✅ | ✅ |
| APK size | +6.4 MB per ABI (measured in arm64 release APK) | much larger | much larger | (already included) | similar to PDFium |

**Decision: PDFium**, through `pdfium_dart` 0.2.x (Dart FFI bindings; its build hook downloads the prebuilt `bblanchon/pdfium-binaries` build and bundles `libpdfium.so`). It's the engine behind Chrome's PDF viewer. It's free for commercial use, works offline, and offers genuine page-object editing. No paid dependency, licence key or account was added, so the app still builds from a clean checkout. MuPDF was ruled out because the AGPL would force the whole app's source to be released under the AGPL, unless a commercial licence is bought.

**Nutrient or Apryse** would add text reflow across arbitrary content streams, complex-script shaping (Hindi), font subsetting and a ready-made UI. Both need a commercial licence, quoted per app or deployment by the vendor. I didn't integrate either. If you want to, contact the vendor for a quote and trial key, then implement `PdfEditEngine` (see §2) with their SDK. The editor UI and edit model don't depend on PDFium.

### Licences of what was added
| Component | Licence |
|---|---|
| PDFium (`libpdfium.so`, from bblanchon/pdfium-binaries) | BSD-3-Clause / Apache-2.0 |
| `pdfium_dart` (bindings) | MIT |
| `ffi` | BSD-3-Clause |
| GNU FreeSans (already bundled) | GPLv3 with font exception (embedding in PDFs is allowed) |

---

## 2. Architecture

```
lib/features/pdf_editor/
  model/edit_state.dart        engine-neutral, JSON-serialisable edit recipe + undo/redo history
  engine/pdf_edit_engine.dart  PdfEditEngine / PdfEditSession interfaces, analysis & report types
  engine/pdfium_engine.dart    PDFium implementation (the only file that touches PDFium)
  engine/text_layout.dart      line breaking, alignment, justification (pure Dart)
  engine/engine_worker.dart    runs the engine on its own isolate (UI never blocks)
  editor/                      workspace UI: canvas, tools, sheets, pages, OCR, signatures, drafts
  pdf_editor_launcher.dart     entry points, password prompts, draft recovery
```

- **Non-destructive.** `EditState` holds page slots (order, rotation, blank pages), edits of existing text blocks and image objects, added items (text, images, covers, OCR text, annotations) and document-wide decorations. Previews and exports apply it to a fresh copy of the original bytes.
- **Undo/redo.** Every change pushes a new immutable state, up to 200 steps.
- **Drafts.** Each session has a draft folder in app-private storage: `editor_drafts/<id>/` with a copy of the original, `state.json` and inserted images. It's autosaved 0.7 s after each change, so edits survive the app being killed. Passwords are never stored: a protected draft asks again when you resume it.
- **Threading.** PDFium isn't thread-safe. One worker isolate owns it for the whole session. The UI sends edit states and receives rendered pixels, analysis results and exported bytes.
- **Coordinates.** All geometry is in "display points": PDF points measured from the top-left of the page as displayed, with the page's own rotation applied. The engine converts to PDF user space, including for rotated pages and offset crop boxes.

---

## 3. How text editing works

1. **Analysis.** Each page's text objects are read with their text, font (base name, embedded or subset, weight, italic), effective size (font size × text matrix), fill colour, baseline, bounds and orientation. Runs on the same baseline become lines. Consecutive lines with the same font, size and colour, regular leading and horizontal overlap become a paragraph block. Alignment (left, right, centre, justified) is detected from the line edges.
2. **In-place rewrite.** This is the most faithful path. When a block is one text object, the change stays on one line and the formatting isn't changed, the object's text is replaced in place. Font, size, colour, character and word spacing and position all stay exactly as they were.
3. **Rebuild.** For other edits (multi-line paragraphs, style changes, moved or resized boxes), the original objects are removed and new text objects are laid out. Line breaking, alignment and justification happen inside the block's width. Line spacing is measured from the original. A single-line label grows to the right, and a paragraph reflows downward. **Keep inside the original box** shrinks the font size instead.
4. **Font matching.**
   - The **original embedded font is reused** when the user didn't change bold or italic and the font has a real glyph for every character typed. PDFium is asked for each glyph outline, and characters that resolve to `.notdef` or an empty outline count as missing. This is how subset fonts are detected.
   - Otherwise the closest **standard PDF font** is used: Times, Helvetica or Courier, matched from the original font name, with bold and italic variants. It covers Western European text.
   - Characters outside Western European text use the bundled **FreeSans** (Unicode, embedded).
   - The editor **always says which font was used and why**. "Check font & layout" shows this before applying, and a notice appears after applying. It never claims an exact match it didn't achieve.
5. **Overlap check.** The result is compared with neighbouring text and images, and you're warned if it overlaps them.

---

## 4. Feature checklist

Legend: ✅ complete · 🟡 partial (limits listed) · ❌ not supported

### A. Edit existing text
| Feature | Status | Notes |
|---|---|---|
| Select a text block or paragraph by tapping | ✅ | Blocks are outlined in Edit Text mode. Edited blocks are green. |
| Edit with a text cursor and keyboard | ✅ | Bottom sheet with a multi-line text field. |
| Correct words and sentences, add text, delete text or whole blocks | ✅ | |
| Font family, size, colour, bold, italic, alignment (left/centre/right/justify) | ✅ | |
| Line spacing | ✅ | |
| Character spacing | 🟡 | Kept in the in-place path. When text is rebuilt, the original character and word spacing isn't reproduced and can't be adjusted. PDFium has no setter for it. |
| Resize (width handle) and move blocks | ✅ | |
| Preserve layout, margins, line breaks | 🟡 | Exact for in-place rewrites. Rebuilt paragraphs reflow inside the original width with the measured leading. Content around the block isn't moved. |
| Preview before saving | ✅ | "Check font & layout", live page render, and compare with the original (⇄). |
| Rotated or skewed text | 🟡 | Can be rewritten, but becomes upright (with a warning). |
| Text inside form XObjects or Type 3 fonts | ❌ | Not editable in place. A banner explains this. Use Add Text with a cover instead. |
| Selection handles, contextual toolbar, pinch zoom, drag, long press | ✅ | Long press selects pages in the Pages view. Pages are re-rendered at a higher resolution when zoomed. |

### B. Font matching
| Feature | Status | Notes |
|---|---|---|
| Read font name, embedding, subset, size, colour, bold/italic, baseline, alignment, paragraphs | ✅ | Shown under "Font info". |
| Reuse the original embedded font when its glyphs exist | ✅ | Glyph-level check. Works for full and subset fonts. |
| Clear warning when a substitute is used | ✅ | |
| Hindi (Devanagari) in-place editing | 🟡 | Text is found and can be rewritten with FreeSans, but PDFium doesn't shape Indic scripts, so conjuncts and vowel signs may render wrongly. The editor warns about this, and the preview shows the real result. Better shaping would need HarfBuzz or a commercial SDK. |
| Exact font metrics in substitutes | 🟡 | Standard fonts differ in width from the original. Line breaking uses the substitute's real metrics. |

### C. Add new text
| Feature | Status | Notes |
|---|---|---|
| Tap anywhere to add a text box; font, size, colour, style, alignment, line spacing | ✅ | Written as real, selectable PDF text (checked with Poppler in tests). |
| Move, resize (width), rotate, duplicate, delete | ✅ | |
| Quick actions: date (2 formats), subject, ref. no., remarks, name, address | ✅ | |
| Opacity | ✅ | |

### D. Images
| Feature | Status | Notes |
|---|---|---|
| Insert from gallery, files, camera or images saved in ScanPro (passport photos, seals, logos, scanned pages) | ✅ | |
| Move, resize (aspect ratio kept), rotate, crop, opacity, duplicate, delete | ✅ | For inserted images. |
| JPEG kept unrecompressed, PNG transparency kept | ✅ | Photos over 3000 px are reduced to 3000 px (about 300 dpi on A4). |
| Existing images in the PDF: move, resize, replace, delete | ✅ | |
| Existing images: rotate, crop, duplicate | ❌ | Replace them with an edited copy instead. |
| Existing images: transparency | 🟡 | Applies when the image is replaced. |
| Selection borders and handles are never exported | ✅ | They're drawn by the app, not in the PDF. |
| Undo/redo | ✅ | |

### E. Signatures
| Feature | Status | Notes |
|---|---|---|
| Draw (finger or stylus; colour and thickness), import an image with background clean-up and crop | ✅ | |
| Multiple saved signatures, private and local, deletable | ✅ | Signatures drawn with the old annotation tool are converted. |
| Place anywhere, move, resize, rotate | ✅ | |
| Name, designation and date beside the signature | ✅ | |
| Preview and save the signed document | ✅ | |
| Clearly labelled as an image, not a digital signature | ✅ | |
| Cryptographic digital signature | ❌ | Not implemented. |

### F. Annotations, stamps, document tools
| Feature | Status | Notes |
|---|---|---|
| Highlight, underline, strikethrough (snap to text lines) | ✅ | PDF markup annotations. |
| Freehand pen, rectangle, ellipse, line, arrow | ✅ | Lines and arrows are saved as ink annotations. |
| Notes and comments | ✅ | PDF text (sticky-note) annotations. |
| Text stamps: Draft, Approved, Reviewed, Confidential, Rejected, Paid, Received, Copy, custom; optional date; image stamps (seal, logo) | ✅ | PDF stamp annotations with appearance streams. |
| Annotations stay editable until flattened; optional flatten on save | ✅ | Flattening also flattens existing form fields. The save sheet says so. |
| Change the colour of an added annotation | ✅ | |
| Edit annotations that were already in the PDF | ❌ | They're preserved, not editable. |
| Watermark, header, footer, page numbers (custom format) | ✅ | Real text on every page. Shown in the preview. |
| Rotate, insert blank, extract, delete, reorder pages | ✅ | |
| Duplicate pages | ❌ | |

### G. Scanned PDFs (OCR)
| Feature | Status | Notes |
|---|---|---|
| Detect image-only pages | ✅ | No visible text and more than 50% image coverage. Never presented as editable text. |
| Run OCR (English or Hindi, on device), show confidence and flagged lines, correct them | ✅ | Uses the app's existing ML Kit OCR. |
| Add a searchable invisible text layer | ✅ | The scan isn't changed. |
| Replace a line visually (paper-coloured cover plus new text) | ✅ | An explicit, confirmed overlay that can be undone or removed. The scan underneath stays. |
| Explain image editing vs OCR correction vs PDF text editing | ✅ | Shown on the OCR screen and in the page banner. |

### Workspace and safety
| Feature | Status |
|---|---|
| Tool sections: Edit Text, Add Text, Edit Image, Insert Image, Sign, Annotate, Stamp, OCR, Pages, Save & Export | ✅ |
| Undo/redo, unsaved indicator, compare with original, zoom, page navigation | ✅ |
| Autosaved drafts, recovery after closing, confirmation before discarding | ✅ |
| Large PDFs: pages are loaded on demand on a worker isolate; thumbnails are lazy | ✅ (300-page test) |
| Save as a new version by default; replace the original only after confirmation | ✅ |
| Keep password protection (same password and encryption) or remove it on request | ✅ |
| Owner restrictions respected: editing is refused when the PDF forbids modification for the password used | ✅ |
| Validation: the written file is re-opened, page count and every page are checked, existing annotations, links and form widgets are counted before and after | ✅ |
| Page order, sizes, links, bookmarks, form fields, existing annotations and metadata preserved | ✅ (PDFium rewrites the same objects. Covered by tests.) |
| No logging of document content, signatures or passwords | ✅ |

---

## 5. Known limitations

- **Hindi and other complex scripts** aren't shaped when written as PDF text (see B).
- When **FreeSans** is needed (non-Western text), the whole 1.8 MB font is embedded once per saved file. PDFium doesn't subset fonts.
- **Standard fonts** (Helvetica, Times, Courier) aren't embedded. That's valid PDF, and every viewer has them, but the shapes vary slightly between viewers.
- **Paragraph reflow** applies inside the edited block only. Text below it isn't pushed down. Instead you get an overlap warning, so you can resize the box or use "Keep inside the original box".
- Text that's split into many tiny objects (character-positioned PDFs) is grouped into lines and paragraphs heuristically. Unusual layouts can group differently from how they look.
- **Syncfusion's text extractor**, which the existing PDF tools use, can't read the Unicode text map PDFium writes for FreeSans. Standard viewers can. Edited files saved in the app are indexed for search with PDFium's extractor instead.
- Pages are rendered by PDFium inside the editor and by Android's renderer in the existing viewer. Rare rendering differences between the two are possible.

---

## 6. Licensing, keys and deployment

- No API key, licence key, account or network access is needed at runtime. The editor is fully offline.
- **Building** needs network access once: `pdfium_dart`'s build hook downloads PDFium binaries from GitHub (`bblanchon/pdfium-binaries`, release `chromium/7811`). On an offline build machine, pre-populate `.dart_tool/hooks_runner` or provide the library and set `PdfiumEngine.modulePath`.
- APK size grows by about 6.4 MB per ABI (measured: `lib/arm64-v8a/libpdfium.so` in the release APK).
- **iOS (future):** add `pdfium_flutter`, which links the PDFium XCFramework. `pdfium_dart` then loads it from the process.

## 7. Tests

`test/pdf_editor_test.dart` builds real PDF files with three different producers (a hand-written raw PDF, Syncfusion and PDFium) and covers the ten requested cases. `test/pdf_editor_widget_test.dart` runs the real editor screen with the PDFium worker isolate. Text that a standard viewer would extract is checked with Poppler's `pdftotext`, which CI installs.

| # | Case | What is verified |
|---|---|---|
| 1 | Digitally generated PDF (unembedded Helvetica, scaled text matrix) | Typo fixed in place; same font, size (10 pt via `Tm`), baseline position; other text untouched; original bytes unchanged (SHA-256). |
| 2 | Fully embedded TrueType font | Original font reused for new characters (ü, —, ₹); text extractable by a standard viewer. |
| 3 | Subset font | Glyphs already in the subset → original font reused; missing glyphs → substitute + warning. |
| 4 | Mixed sizes and colours | Separate blocks; edited block gets new size/colour/bold font; other blocks keep colour, size, position. |
| 5 | Scanned image-only page | Detected as scanned, no fake text blocks; OCR layer + cover + replacement text added; scan image (600×800 px) preserved. |
| 6 | Hindi + English | English block edited; Devanagari edit produces the shaping warning. |
| 7 | Multi-page with headers/footers | Reorder, delete, rotate, insert blank, custom page numbers, extract subset; order verified per page. |
| 8 | Images, links, form fields | Link and form field (with its value) kept; image moved; photo and transparent signature placed at exact position and size; highlight, ink, stamp, note created as annotations with appearance streams; stamp visible in a render; flatten burns the stamp into the page. |
| 9 | Password-protected (AES-256) | Password required, wrong password reported; export keeps encryption; text readable with the password. |
| 10 | Large PDF (300 pages) | Edit page 151, export, validate 300 pages, neighbouring page unchanged. |
| + | Paragraph reflow | 3-line paragraph grouped; longer text wraps inside the width; shrink-to-fit stays inside the box; added text selectable. |
| UI | Editor workspace (widget test) | Real render through the worker, tap selection, all tool sections, page navigation, undo/redo, autosaved draft restored, export validated. |
