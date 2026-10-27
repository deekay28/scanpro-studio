# Document productivity suite

ScanPro Studio now has conversions, a reader, comparison, forms, links, annotation management, redaction, protection, compression profiles and page tools. They're built into the existing app; nothing was moved into a separate app, and the scanner, OCR, PDF editor and passport-photo modules are unchanged.

Everything runs **on the device**. No document, page image or text is uploaded, and the release APK still has no `INTERNET` permission.

## 1. Where to find it

| Entry point | What it opens |
|---|---|
| Home → **Convert**, **Read PDF**, **Fill & sign**, **Compare PDFs** | Conversion Centre, or pick a PDF for the tool |
| Tools → **Convert** section | Conversion Centre and the job queue/history |
| Tools → **Read, review & secure** section | Every document tool (it asks you to pick a PDF first) |
| PDF viewer (any PDF in Documents) → **⋮ More tools** | Every tool for that PDF, including Convert |
| Documents → **New** → **Convert a file** | Conversion Centre for Word/Excel/PowerPoint/HTML/text/image files |
| Documents → long-press → **Select** | Multi-select with batch actions |

Every tool writes a **new copy**. The original is never modified. Results open in the PDF viewer, where you can save them to Documents or the device, share them or print them.

## 2. Feature matrix

Legend: ✅ complete · 🟡 partial (limits described) · ⏳ not implemented

### Conversion Centre
| Feature | Status | Notes |
|---|---|---|
| PDF → Word (DOCX): **Faithful layout** (page-sized original image per page), **Editable document** (text, tables, shaded bands and pictures rebuilt at their original positions; scans straightened and read with OCR, seals/stamps/signatures/QR codes kept as pictures) and **Automatic** (per page) | ✅ | See [PDF_TO_WORD_LAYOUT.md](PDF_TO_WORD_LAYOUT.md): diagnosis, stages, measured visual-comparison results and limits. Uncertain OCR words are highlighted |
| PDF → Excel (XLSX): ruled and borderless tables, typed numbers/dates/currency, one sheet per table or per page, source note per sheet | ✅ | Uncertain cells keep their original text and are highlighted. If no table is found, lines can be exported instead |
| Table **review before export**: edit cells, delete/merge/split/insert columns, delete rows, set the header row; export XLSX or CSV | ✅ | PDF → Excel/CSV and PowerPoint → Excel, single file |
| PDF → PowerPoint: **visual** (page images, labelled) and **editable** (text boxes + pictures) | ✅ | Scanned pages become labelled picture slides |
| PDF → JPG / PNG / TIFF: DPI, page ranges, grayscale, JPEG quality, file-name template, ZIP, size estimate | ✅ | Pages are rendered one at a time to keep memory low |
| PDF → TXT, HTML, CSV | ✅ | |
| Images → PDF (order, A4 fit or image size) | ✅ | |
| Word → PDF, Excel → PDF (cell range), PowerPoint → PDF (slide range), HTML → PDF, text → PDF | 🟡 | Rendered by the app itself, so no Office or cloud service is needed. Text, tables, lists, pictures and simple bar charts are kept. Exact fonts, shapes, SmartArt, themes and complex layout are approximated, and the result says so |
| PowerPoint → Excel: tables, chart data (only when stored in the file; never guessed from pictures), text, bullets, key: value pairs, one sheet per slide or combined, slide numbers, slide selection | ✅ | |
| Excel → PowerPoint: sheets and cell ranges, tables split over slides so they stay readable, native bar charts | ✅ | No custom templates; one built-in clean theme |
| OCR for scanned pages (English/Latin, Hindi/Devanagari) | ✅ | ML Kit, on-device |
| Batch: several files in one job, per-file and overall progress, cancel, retry, failures listed, unique names for duplicates | ✅ | |
| Job history and recovery: queue saved to disk; jobs cut off by an app kill show as **Interrupted** and can be retried | ✅ | Passwords are kept in memory only and asked again after a restart |
| Background processing | 🟡 | Jobs run in background isolates while the app is open. There's no Android foreground service, so a job stops if Android kills the app (it can then be retried) |
| Output validation before success: written to `.part`, reopened (PDF parsed, Office ZIP + XML checked, images decoded), then renamed | ✅ | Empty text output is reported as a failure, not a success |
| Preview, open, share / open with, save to device, share all as ZIP | ✅ | |
| Insufficient storage, damaged files, wrong type, encrypted files, unreadable files: clear messages | ✅ | |
| Converting from the share sheet of other apps (receiving shared files) | ⏳ | Use the in-app file picker |

### Reading and review
| Feature | Status | Notes |
|---|---|---|
| Reader: continuous, single page, two pages, book (cover alone) | ✅ | Pinch-zoom in page modes; double-tap a page in continuous mode to zoom in |
| Light, dark (inverted), sepia and custom backgrounds; full screen | ✅ | |
| Thumbnails, table of contents (outline), personal bookmarks, search with highlights, go to page | ✅ | |
| Copy text from a page, read aloud from the current page (Android text-to-speech, speed control) | ✅ | Needs a TTS engine with the language installed (most phones have one). Scanned pages need OCR first |
| Resume at the last page, recently read list | ✅ | Copies stay in app storage. Passwords are not stored |
| Compare two PDFs: inserted, deleted and changed text, changed numbers, page count and size changes, side-by-side with synchronised scrolling, highlights, jump to change, report as PDF or Word | ✅ | Only extracted text is compared, so re-saving or font changes don't create false changes. Pages that are scans on both sides are compared visually, and the result is labelled "visual difference" |

### Forms, links, annotations, bookmarks
| Feature | Status | Notes |
|---|---|---|
| Fill AcroForm fields (text, checkbox, choices, dropdown, list); save filled or flattened | ✅ | |
| Signature fields: place a signature image in the field's area | ✅ | An image of a handwritten signature, not a certificate-based digital signature |
| Flat (non-fillable) forms | 🟡 | Typed text and signatures are placed with the PDF editor. Blanks are not detected automatically |
| XFA forms | ⏳ | Detected and reported; only their AcroForm part (if any) can be filled |
| Create fillable fields: text (max length, multi-line), checkbox, choice buttons, dropdown, signature | ✅ | Fields stay editable in other PDF apps |
| Links: list, add (web, e-mail, page), edit, remove; undo/redo | ✅ | |
| Annotation summary by type, export/import XFDF / FDF / JSON, flattened copy (links and fields stay live) | ✅ | Adding/editing annotations is in the PDF editor |
| Bookmarks (outline): add, add nested, remove | ✅ | |
| Headers, footers, page numbers ({page} of {pages}), dates, titles, file name, margins, alignment, page ranges, first number, text and image watermarks, background tint, preview | ✅ | The tint is blended over the page (multiply), so pictures are tinted too |

### Security
| Feature | Status | Notes |
|---|---|---|
| **True redaction**: mark areas or find text; characters, image pixels, vector paths and annotations inside are removed; the file is rebuilt (no old revisions, metadata, bookmarks, attachments); the result is **verified** by searching for the removed text | ✅ | Pages whose content can't be edited precisely are converted to images (reported). The redacted copy has no password |
| Password protection AES-256 with optional permissions (print, copy, edit, comments, forms, assembly, accessibility) | ✅ | Restrictions are respected by standard PDF apps but can't stop screenshots or software that ignores them. The app says so |
| Remove password (with the current password) | ✅ | Existing tool |

### Compression and structure
| Feature | Status | Notes |
|---|---|---|
| Profiles: high quality, balanced, small, email, messaging, print, optional grayscale, before/after sizes | ✅ | Only pictures are resampled. Text, links, forms, comments and bookmarks are kept. It's not described as lossless, and no result is offered when nothing shrinks |
| Rasterising compression (smallest) | ✅ | Existing tool; it warns that it turns pages into images |
| Blank, lined, grid and dotted pages (A4/Letter), replace pages from another PDF, repair | ✅ | |
| Merge, split, extract, reorder, rotate, delete | ✅ | Existing tools and the PDF editor's page tools |
| PDF/A export | ⏳ | Not offered, because the app can't verify PDF/A conformance |

### Library
| Feature | Status | Notes |
|---|---|---|
| Folders, favourites, tags, recent, search (names, tags, OCR and PDF text), grid/list, trash, import | ✅ | Existing |
| Type filters (scans, PDFs, photo sheets), sort by name, date created, date modified, **size** | ✅ | |
| Multi-select: select all, delete, move, favourite, tag, sequential rename, duplicate, share PDFs, export as ZIP | ✅ | |
| Duplicate a document (full independent copy) | ✅ | |
| Subfolders | ⏳ | Folders are one level deep |

### Optional AI tools
| Feature | Status | Notes |
|---|---|---|
| Summaries, chat with documents, smart extraction | ⏳ | Not implemented. Doing this offline needs an on-device model (hundreds of MB), and a cloud model would need network access and consent. Neither was added, so documents never leave the device |

## 3. Architecture

```
lib/features/convert/
  conversion_service.dart     ConversionService: every conversion type, temp-then-validate-then-rename,
                              cancellation, OCR hook, table preview
  conversion_jobs.dart        ConversionJobManager: persistent queue/history, recovery, retry
  pdf_to_doc.dart             PDF → document model (editable/layout), HTML, text, CSV, editable slides
  table_extraction.dart       TableExtractionService (ruled + aligned tables, typed cells)
  doc_to_pdf.dart             document model / slides → PDF renderer (Office/HTML/text → PDF)
  office_conversions.dart     HTML/text → model, sheets ↔ slides, PowerPoint → sheets
  ooxml/                      dependency-free DOCX/XLSX/PPTX writers and readers
  model/                      PageContent (words, lines, images, rules), DocModel
  ui/                         Conversion Centre, jobs/history, output preview, table review
lib/features/docsuite/
  suite.dart                  DocSuite: shared PDFium host, conversion service, job manager, ML Kit OCR
  services/                   PdfFormService, PdfLinkService, PdfAnnotationService, PdfOutlineService,
                              PdfStampService, PdfSecurityService, PdfComparisonService
  ui/                         reader, compare, forms, links, annotations, bookmarks, redaction,
                              protection, compression, page tools, headers/footers, "More tools" menu
lib/features/pdf_editor/engine/
  engine_worker.dart          PdfiumHost: one app-wide isolate owning PDFium (it isn't thread-safe);
                              sessions are served one call at a time
  pdfium_tools.dart           content extraction, rendering to JPG/PNG/TIFF, outline, search, annotations
  pdfium_security.dart        redaction, image optimisation, pattern pages, page replacement
```

The services that the spec names map like this: `PdfConversionService` and `OfficeConversionService` are `ConversionService` with the `pdf_to_doc` and `doc_to_pdf`/`office_conversions` modules; `TableExtractionService` and `ConversionJobManager` keep those names; `OcrConversionService` is the `OcrRecognizer` hook (ML Kit in the app, a stand-in in tests); `PdfSecurityService`, `PdfComparisonService` (`compareText`/`compareRender`) and `PdfFormService` keep their names. Vendor code (PDFium, Syncfusion, ML Kit) stays behind these classes, so an engine can be swapped without touching the screens.

Heavy work runs off the UI thread: PDFium calls in the host isolate; Office writing, table extraction and comparison through `compute` with top-level functions, so only explicit arguments are sent between isolates.

**iOS readiness.** All of this code is platform-neutral Dart. PDFium has iOS builds, and flutter_tts and ML Kit support iOS. The iOS project and signing aren't set up yet (see README roadmap).

## 4. Dependencies and licensing

One new package was added for this work: **flutter_tts 4.2.x** (MIT), used for read aloud. It uses Android's built-in text-to-speech engine and doesn't call any online service; `tool/configure_android.py` adds the `TTS_SERVICE` package-visibility query that Android 11+ requires.

Other packages these features rely on were already dependencies:

| Package | License | Used for |
|---|---|---|
| pdfium_dart (PDFium) | MIT (wrapper); PDFium BSD-3/Apache-2.0 | rendering, text/content extraction, search, redaction, optimisation |
| syncfusion_flutter_pdf | Syncfusion Community License (free for individuals and companies under US$1M revenue; otherwise a paid license) | forms, links, annotations import/export, bookmarks, headers/footers, encryption, creating PDFs |
| xml | MIT | OOXML reading/writing |
| html | BSD-3 | HTML → PDF |
| archive | MIT | OOXML packages, ZIP export |
| google_mlkit_text_recognition | Google ML Kit terms | OCR |

**No paid SDK was added.** Commercial SDKs (Apryse, Nutrient/PSPDFKit, ComPDFKit, Aspose) would convert Office files with better fidelity, but they cost roughly US$1,500–10,000+ per year per app and some need a license key. The hand-written OOXML code covers the requested conversions with honest warnings instead. If exact Office layout fidelity becomes essential, an Office-rendering SDK is the upgrade path, and that would be a cost decision for you.

**Credentials:** none are needed. No API keys, accounts or license keys.

Test-only tools: python-docx, openpyxl and python-pptx (MIT/BSD) validate Office output in CI; LibreOffice and Poppler are used when installed.

## 5. Privacy and reliability

- Processing is local. Nothing is uploaded, and there's no network permission in release builds.
- Document text and metadata aren't logged. Error messages name the file and the problem, not the content.
- Passwords live only in memory for the job or screen that needs them and are never written to the job history.
- Originals are never modified. Outputs are written to a temporary `.part` file, validated, then renamed. A cancelled or failed job deletes its partial output.
- Large documents are processed page by page: one page's content or image at a time, with a bounded render cache in the reader.
- No silent downgrades: when a feature is approximated (fonts, layout, scanned pages, picture-only charts), the result lists a warning.

## 6. Acceptance tests (actual results)

All were run with `flutter test` on Linux (Flutter 3.47.8). CI runs the same tests on every push.

| # | Test | Result | Where |
|---|---|---|---|
| 1 | Multi-page digital PDF → DOCX (editable and layout), checked with python-docx and LibreOffice | ✅ passed | `test/conversion_test.dart` |
| 2 | PDF with tables → XLSX and CSV (typed values, sheets per table/page), checked with openpyxl | ✅ passed | `test/conversion_test.dart`, `test/conversion_jobs_test.dart` (table review) |
| 3 | PDF → PPTX visual and editable, checked with python-pptx and LibreOffice | ✅ passed | `test/conversion_test.dart` |
| 4 | Scanned PDF through OCR → DOCX, uncertain words flagged; without OCR the user is told | ✅ passed | `test/conversion_test.dart`, `test/conversion_jobs_test.dart` (OCR is a stand-in recogniser in tests; ML Kit only runs on a device) |
| 5 | Multi-page PDF → JPG/PNG/TIFF, DPI, grayscale, ranges, ZIP and name template | ✅ passed | `test/conversion_test.dart`, `test/conversion_jobs_test.dart` |
| 6 | PPTX with tables and a chart → Excel (chart values from the file; a chart without data is reported, not invented) | ✅ passed | `test/conversion_test.dart` |
| 7 | XLSX → PowerPoint (table slides, native chart, range, pagination) | ✅ passed | `test/conversion_test.dart` |
| 8 | Several files in one batch job | ✅ passed | `test/conversion_jobs_test.dart` |
| 9 | Password-protected documents: conversion fails without the password, retry succeeds, password never stored; protection with permissions | ✅ passed | `test/conversion_jobs_test.dart`, `test/docsuite_services_test.dart` |
| 10 | Forms, annotations, links and bookmarks preserved (fill, flatten, create fields, links, XFDF/JSON, flatten copy keeps links/fields, bookmarks) | ✅ passed | `test/docsuite_services_test.dart` |
| 11 | PDF comparison finds known inserted, deleted and changed text and page changes | ✅ passed | `test/docsuite_services_test.dart` |
| 12 | Redaction: removed text, pixels, links and metadata can't be recovered from the file (raw bytes and decompressed streams searched) | ✅ passed | `test/security_tools_test.dart` |
| 13 | 200-page document converted, then rendered to 200 images, without crash | ✅ passed | `test/conversion_jobs_test.dart` (memory measured only indirectly: page-at-a-time processing; not profiled on a phone) |
| 14 | Exported DOCX/XLSX/PPTX reopened in independent readers: python-docx/openpyxl/python-pptx and the app's own readers; LibreOffice converted every file to PDF | ✅ passed | `test/conversion_test.dart` (LibreOffice part runs only where it's installed: locally yes, CI no) |
| 15 | Output validation, cancellation (no partial files), retry, recovery after the app is killed | ✅ passed | `test/conversion_jobs_test.dart` |
| UI | Conversion Centre and setup options, table review editing, reader (render, bookmark, layouts, resume) | ✅ passed | `test/docsuite_widget_test.dart` |

**Not run:** tests on a physical phone (camera, ML Kit OCR, text-to-speech, sharing to other apps, opening outputs in Microsoft Office/Google apps). Use the checklist in `docs/TESTING.md`, Workflows H and I.

**Existing features:** the scanner, OCR, PDF editor and passport-photo test suites (`repository_test`, `imaging_test`, `pdf_test`, `print_layout_test`, `text_and_models_test`, `pdf_editor_test`, `pdf_editor_widget_test`, `widget_test`) still pass unchanged.

## 7. Known limitations

- Office → PDF is an approximation (fonts, shapes, SmartArt, themes, complex layout). Use Microsoft Office or LibreOffice when exact layout matters.
- PDF → Word can't recover real columns, text boxes, equations or handwriting as editable structure; it warns when they're likely present. Layout-preserving limits (bold on photos, paper curl, estimated fonts) are listed in [PDF_TO_WORD_LAYOUT.md](PDF_TO_WORD_LAYOUT.md) §5.
- Table detection works on ruled grids and clearly aligned columns. Merged cells and irregular tables need the review screen.
- Hindi text is extracted and converted, but complex Devanagari shaping in generated PDFs depends on the font renderer.
- Form and link coordinates assume unrotated pages; rotated pages may place new fields offset.
- Redaction rasterises pages it can't edit precisely, which removes selectable text on those pages.
- Jobs don't continue after Android kills the app (they can be retried).
- No PDF/A, XFA, subfolders, share-intent import or AI features (see the matrix).

## 8. Files changed for this feature set

New: `lib/features/convert/**` (conversion service, job queue, OOXML, converters, UI), `lib/features/docsuite/**` (suite, services, UI), `lib/features/pdf_editor/engine/host_ops.dart`, `pdfium_tools.dart`, `pdfium_security.dart`, tests `conversion_test`, `conversion_jobs_test`, `convert_support`, `docsuite_services_test`, `docsuite_widget_test`, `ooxml_test`, `security_tools_test`, `test/tools/*.py`, this document.

Changed: `engine_worker.dart` (shared host), `pdfium_engine.dart` (repair, parts), `core/repository.dart` (duplicate, size), `library_screen.dart` (multi-select, filters, size sort), `home_screen.dart`, `tools_screen.dart`, `pdf_viewer_screen.dart` (entry points), `pubspec.yaml` (flutter_tts), `tool/configure_android.py` (TTS query), CI workflow (Python validators, Poppler), README, TESTING, BUILD_STATUS, `test/repository_test.dart`.
