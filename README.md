# ScanPro Studio

An offline-first Android document scanner, PDF toolkit and editor, document converter, OCR tool and passport/ID photo print studio, built with Flutter.

- **No account, no cloud, no ads, no analytics.** The release APK doesn't request the `INTERNET` permission at all.
- **Non-destructive.** The original capture is always stored byte-for-byte. Crops, filters and adjustments are recipes that can be changed or reverted at any time.
- **Physical units for printing.** Photo sheets are laid out in millimetres and written to PDF in points (1 mm = 72/25.4 pt). They aren't scaled-down screenshots.

> Working title "ScanPro Studio". This app isn't affiliated with CamScanner, Adobe Scan or any passport authority.

---

## 1. Feature matrix

Legend: ✅ implemented · 🟡 implemented with documented limitations · ⏳ not implemented

### Capture & import
| Feature | Status | Notes |
|---|---|---|
| Smart scan (live edge detection, auto-capture, perspective, cleanup) | ✅ | Google ML Kit Document Scanner (runs on-device inside Google Play services). Falls back to the built-in camera if Play services isn't available. |
| Built-in "Pro camera": live preview, edge overlay, auto-capture when stable & sharp, manual shutter, torch/flash, tap-to-focus/expose, exposure slider | ✅ | Edge detection runs on a downsampled luminance frame about 3× per second (pure Dart). |
| Multi-page batch capture, review, retake, delete, reorder | ✅ | |
| Blur / dark / overexposed / cut-off / duplicate / low-resolution warnings | ✅ | Variance of Laplacian, histogram clipping, quad-touches-border, dHash. |
| Save & resume unfinished scan sessions (survives app kill) | ✅ | Every capture is copied into a persistent session immediately. |
| Gallery import (Android Photo Picker, multi-select), file import | ✅ | No storage permission needed. HEIC and other platform formats are converted. Images over ~26 MP are downscaled (flagged). |
| Automatic edge detection on imported photos + manual 4-corner crop with magnifier | ✅ | Two strategies (brightness segmentation, edge-enclosed region) → convex hull → max-area quad. Falls back to the full frame. |
| Page-size detection (A4/Letter/Legal/ID card/receipt) | 🟡 | Aspect-ratio hint only. |
| Auto-straighten (deskew), auto-orient (90° via OCR), fine rotation | ✅ | |

### Image processing (all non-destructive)
| Preset | Status |
|---|---|
| Original, Smart Auto, Document Colour, Vivid Colour, Grayscale, Pure B&W (adaptive Sauvola + global Otsu), High-Contrast Text, Faded Recovery, Receipt, Photo Enhance | ✅ |
| **Official Document Preservation** mode (gentle illumination fix only, no thresholding, preserves stamps/seals/signatures; side-by-side Original vs Enhanced; Revert all) | ✅ |
| Manual brightness, contrast, saturation, highlights, shadows, sharpness, threshold | ✅ |
| Before/after toggle and side-by-side compare | ✅ |
| OpenCV | ⏳ Not used. All processing is in pure Dart isolates (no native build complexity), which is slower than OpenCV on very large images. |

### Book mode
| Feature | Status | Notes |
|---|---|---|
| Capture/import two-page spreads, spread detection | ✅ | |
| Spine detection, split into left/right pages, adjustable spine + overlap so text near the binding isn't cut | ✅ | The split is exact in perspective (homography sub-quad). |
| Shadow/background removal | ✅ | Illumination normalisation. |
| Curved-page flattening | 🟡 | **Approximate.** Fits quadratic curves to the top/bottom page edges against a darker background and resamples each column. Text deep in the gutter may stay curved. It's off by default per page, and the original is always kept. |
| Reading order, right-to-left books, page-order preview | ✅ | |

### PDF
| Feature | Status | Notes |
|---|---|---|
| Single/multi-page PDF from scans; A3/A4/A5/Letter/Legal/"match image"; portrait/landscape/auto | ✅ | |
| Fit / fill / original size, margins, page numbers, watermark, metadata, grayscale | ✅ | |
| Image resolution & JPEG quality presets (print / standard / email / messaging) | ✅ | |
| **Searchable PDF** (invisible OCR text layer) and image-only PDF | ✅ | |
| Password protection (AES-256) and password removal | ✅ | Uses Syncfusion PDF. |
| Import existing PDFs **without flattening** (text stays searchable, text layer indexed) | ✅ | |
| Merge, split by ranges, extract, reorder, rotate, duplicate, delete, insert blank | ✅ | Pages are copied as vector templates. Links/form fields/annotations of source pages aren't carried over. |
| Compress: lossless optimise, or strong (rasterise) with the text layer re-added invisibly | ✅ | |
| PDF → images, PDF text extraction | ✅ | |
| Preview, Android share sheet, save via Storage Access Framework, print via Android print framework | ✅ | |
| Every tool writes a **new** file; originals are never modified | ✅ | |

### PDF editor (in-place content editing)
Full details, SDK evaluation and the complete/partial/unsupported checklist: **[docs/PDF_EDITOR.md](docs/PDF_EDITOR.md)**.

| Feature | Status | Notes |
|---|---|---|
| Edit existing text in place: select blocks/paragraphs, correct, rewrite, delete, move, resize; font, size, colour, bold/italic, alignment, line spacing | ✅ | PDFium page-object editing. Rewrites in the **original embedded font** when it has the glyphs, otherwise the closest standard font, with an explicit warning. |
| Character spacing | 🟡 | Preserved for in-place rewrites only; not adjustable. |
| Hindi text editing | 🟡 | Possible, but Devanagari isn't shaped (a warning is shown). |
| Add text anywhere (real selectable PDF text), quick date/subject/ref./remarks | ✅ | |
| Insert/edit images: move, resize, rotate, crop, opacity, replace, duplicate, delete | ✅ | Existing images: move, resize, replace, delete. |
| Sign: draw, import with background clean-up, saved private signatures, name/designation/date | ✅ | A signature image, not a cryptographic digital signature. |
| Annotations (highlight, underline, strike, pen, notes, shapes, arrows), stamps (presets, custom, image) | ✅ | Real PDF annotations, editable until flattened. |
| Watermark, header/footer, page numbers; rotate/insert/extract/delete/reorder pages | ✅ | |
| Scanned PDFs: OCR, correct, searchable layer, visual line replacement | ✅ | The scan itself is never altered. |
| Undo/redo, compare with original, autosaved drafts with recovery, save as new version, validation on export | ✅ | |
| Password-protected PDFs and edit restrictions | ✅ | Encryption kept by default; restrictions are respected. |

### Document suite: conversions, reader, compare, forms, security
Full matrix (complete/partial/unsupported), architecture, licensing and acceptance results: **[docs/DOCUMENT_SUITE.md](docs/DOCUMENT_SUITE.md)**.
PDF → Word modes (Faithful layout / Editable document / Automatic), the layout pipeline and its visual regression results: **[docs/PDF_TO_WORD_LAYOUT.md](docs/PDF_TO_WORD_LAYOUT.md)**.

| Feature | Status | Notes |
|---|---|---|
| Conversion Centre: PDF → Word/Excel/PowerPoint/JPG/PNG/TIFF/TXT/HTML/CSV; images, Word, Excel, PowerPoint, HTML, text → PDF; PowerPoint ⇄ Excel | ✅ / 🟡 | Office → PDF is rendered by the app and approximates fonts and complex layout |
| Batch jobs with progress, cancel, retry, history, recovery after the app is killed; outputs validated before success | ✅ | |
| Table review (fix columns) before Excel/CSV export | ✅ | |
| Reader: continuous/single/two-page/book, night/sepia/custom, outline, bookmarks, search, read aloud, resume | ✅ | |
| Compare two PDFs (text changes, values, page changes; visual for scans) with report | ✅ | |
| Fill and create forms, links, annotation export/import/flatten, bookmarks, headers/footers/watermarks | ✅ | XFA forms not supported |
| True redaction with verification; AES-256 protection with permissions | ✅ | |
| Compression profiles that keep text, links and forms; lined/grid pages, replace pages, repair | ✅ | |
| PDF/A, AI tools, subfolders, receiving files from the share sheet | ⏳ | |

### OCR & intelligence (on-device)
| Feature | Status | Notes |
|---|---|---|
| English (Latin) OCR | ✅ | Google ML Kit Text Recognition v2, bundled model. |
| Hindi (Devanagari) OCR, also mixed Hindi-English | ✅ | Bundled ML Kit Devanagari model (`text-recognition-devanagari`). |
| More languages | 🟡 | Chinese, Japanese and Korean ML Kit models can be enabled (see §8). Other scripts (Tamil, Bengali, …) aren't supported by ML Kit. |
| Copy / edit / per-line correction / page retry / language per run | ✅ | |
| Uncertain-line flags | 🟡 | Uses the engine's confidence when the plugin exposes it, plus heuristics (symbol ratio, digit/letter confusion, mixed scripts). |
| TXT export, CSV table export | 🟡 | Table structure is best-effort (row/column clustering of line boxes). |
| Dates, amounts/totals, phone numbers, emails, URLs, GSTIN | ✅ | Rule-based suggestions. Always marked "verify". |
| Document type detection (invoice, receipt, certificate, ID, statement, …) and name suggestions | ✅ | Keyword-based, user confirms. |
| **Full-text search** across all documents (FTS4) with page + snippet, kept in sync after edits/deletes, setting to disable/clear | ✅ | Falls back to LIKE search if FTS4 isn't available. |
| On-device LLM summaries / Q&A, grammar, translation | ⏳ | Not implemented. No suitable small on-device model is integrated, and cloud AI is deliberately excluded. |

### Passport & ID Photo Studio
| Feature | Status | Notes |
|---|---|---|
| Capture (rear/selfie) or import a portrait | ✅ | |
| On-device face detection → automatic framing to the preset's head-size rules | ✅ | ML Kit Face Detection. Warns about tilt, side pose or multiple faces. |
| Interactive framing with crown/chin/centre guides, zoom, straighten | ✅ | |
| Background replacement (selfie segmentation), colour choices, manual mask refine brush | ✅ | ML Kit Selfie Segmentation. Result is shown side-by-side with the original crop. |
| Brightness, contrast, saturation, warmth, sharpen, light noise reduction | ✅ | No face reshaping or beauty filters. |
| Editable presets (India 35×45, 2×2 in, Schengen/UK, Canada, China, stamp, ID card, student, job, custom) | ✅ | Labelled "verify with the official source". |
| Print-sheet optimiser: max copies, rows/cols, unused area, sheets needed, best orientation | ✅ | Never shrinks a photo. |
| Copies 2/4/6/8/10/12/custom/fill; manual rows×columns; margins; gaps; cut lines; crop marks; borders | ✅ | |
| A4, 4×6 in, 5×7 in, 3.5×5 in, Letter, A5 | ✅ | |
| PDF (exact physical size), PNG/JPEG at 300/600 dpi with DPI metadata | ✅ | |
| Resolution warning when source DPI < 300 | ✅ | |
| Print-scaling warning + **calibration test page** (100 mm rulers, 50 mm & 1 in squares, edge markers) | ✅ | |

### Organisation, security, extras
| Feature | Status |
|---|---|
| Folders, tags, favourites, recent, grid/list, sort (incl. size), type filters | ✅ |
| Multi-select: delete, move, favourite, tag, sequential rename, duplicate, share, ZIP export | ✅ |
| Recently deleted with configurable retention (7–90 days) | ✅ |
| Duplicate document warning on save | ✅ |
| Annotations: pen, highlighter, text, signatures (saved for reuse), move/resize, undo. Burned into exports | ✅ |
| QR/barcode reading from images; QR generation (incl. local document reference) | ✅ |
| Biometric / device-credential app lock (re-locks after 30 s in background) | ✅ |
| Private vault (AES-256-GCM, key in Android Keystore-backed secure storage, device auth) | ✅ |
| Local backup/restore ZIP; export a document as ZIP | ✅ |
| Version lineage (derived PDFs keep a parent reference) | 🟡 |
| WebDAV/cloud backup | ⏳ (deliberately not included; share the backup ZIP to a storage app instead) |
| Document comparison | ✅ (see Document suite) |
| Material 3, light/dark/system theme, phone/tablet layouts (navigation rail ≥ 840 dp), semantics labels/tooltips | ✅ |

---

## 2. Architecture

```
lib/
  main.dart, app.dart          bootstrap, theme, app-lock gate
  core/                        models, SQLite (migrations), repository, storage, settings, search, naming, units
  imaging/                     pure-Dart image pipeline (runs in isolates)
    image_ops.dart             filters, adaptive threshold, illumination normalisation, resize, rotation
    perspective.dart           homography, perspective warp, quad helpers
    edge_detect.dart           document quad detection
    quality.dart               blur/exposure/duplicate metrics
    book.dart                  spine detection, curved-page flattening, deskew
    filters.dart               presets → pipeline
    processor.dart             isolate entry points (process page, previews, analysis, spreads)
  features/
    scanner/                   smart scan, pro camera, review, session recovery
    editor/                    crop editor, page editor
    library/                   documents, search, page viewer, trash
    pdf/                       PDF engine (Syncfusion), tools, export, viewer
    pdf_editor/                in-place PDF editor: engine interface, PDFium engine (worker isolate),
                               edit model (undo/redo, drafts), workspace UI, signatures, OCR overlay
    convert/                   Conversion Centre: conversion service, job queue, OOXML (DOCX/XLSX/PPTX)
                               readers/writers, table extraction, Office/HTML/text → PDF, UI
    docsuite/                  shared document services (forms, links, annotations, bookmarks, stamps,
                               security, comparison), reader, compare and tool screens
    ocr/                       ML Kit OCR, text analysis, OCR UI
    passport/                  presets, layout engine, renderer, studio UI, calibration
    book/  annotate/  qr/  security/  backup/  settings/  tools/  home/  shell/
  shared/                      theme and reusable widgets
test/                          unit, widget and repository tests
tool/configure_android.py      patches the generated Android project
.github/workflows/build-apk.yml  CI: analyze → test → build APKs → GitHub Release
```

**Data model.** `documents` and `pages` tables (SQLite via sqflite, versioned migrations in `core/database.dart`). Each page stores the relative path of the untouched original, the current processed render, a thumbnail, the JSON edit recipe (`PageEdit`), the OCR JSON path and text, quality flags, a perceptual hash and annotation files. Image data lives in files under app-private storage, not in the database. `page_fts` (FTS4) indexes OCR and PDF text.

**State.** Riverpod providers expose the repository (a `ChangeNotifier`) and settings. Screens rebuild on repository revisions.

---

## 3. Dependencies

All versions are constrained in `pubspec.yaml`. CI resolves the newest compatible set.

| Package | Purpose |
|---|---|
| flutter_riverpod 2.x | state management |
| sqflite, path_provider, path | metadata database, storage paths |
| camera | Pro camera (preview, focus, exposure, torch, image stream) |
| image_picker | Android Photo Picker, system camera |
| file_picker | open PDFs/ZIPs, save files via Storage Access Framework |
| google_mlkit_document_scanner | smart scan (Play services, on-device) |
| google_mlkit_text_recognition (+ `text-recognition-devanagari` Gradle artifact) | OCR |
| google_mlkit_face_detection | passport auto-framing |
| google_mlkit_selfie_segmentation | background replacement |
| google_mlkit_barcode_scanning | QR/barcodes |
| image 4.2.x | decode/encode in isolates |
| pdfium_dart 0.2.x + ffi | PDF editor engine: PDFium (BSD-3/Apache-2.0) via FFI. The build hook downloads and bundles `libpdfium.so` (about 6.4 MB per ABI). No key, account or runtime network. |
| syncfusion_flutter_pdf | PDF create/merge/split/encrypt/text extraction ([Syncfusion Community License](https://www.syncfusion.com/products/communitylicense): free for individuals and small companies; check your eligibility) |
| printing | preview, rasterising, Android print |
| share_plus | share sheet |
| local_auth | biometric / device-credential auth |
| flutter_secure_storage | vault key (Android Keystore) |
| cryptography | AES-256-GCM vault encryption |
| archive 3.x | backup ZIP |
| qr_flutter | QR generation |
| xml, html | OOXML reading/writing, HTML → PDF |
| flutter_tts (MIT) | read aloud in the reader (Android's built-in speech engine, offline) |
| sqflite_common_ffi (dev) | repository tests on desktop |

Font: GNU FreeSans (GPLv3 with font exception) is bundled for the invisible OCR text layer. It covers Latin and Devanagari.

---

## 4. Getting the APK

### Option A: GitHub Actions (no local setup)
1. Push this folder to a GitHub repository (branch `main`).
2. The **Build Android APK** workflow runs automatically. It creates the Android project, runs analysis and tests, then builds:
   - `ScanProStudio-arm64-v8a.apk`: for almost all phones from the last ~7 years (smaller)
   - `ScanProStudio-universal.apk`: works on every device (larger)
3. Download from **Releases → Latest** (`https://github.com/<you>/<repo>/releases/latest`) or from the workflow run's artifacts.
4. On the phone, open the APK and allow "Install unknown apps" for your browser or file manager.

The APK is signed with the Flutter debug key. That's fine for personal sideloading, not for Google Play (see §10).

### Option B: Build on Windows
1. Install **Git**, **Android Studio** (it includes the Android SDK and a JDK) and the **Flutter SDK** (stable): <https://docs.flutter.dev/get-started/install/windows/mobile>.
2. In Android Studio → SDK Manager, install the Android SDK Platform (latest), Build-Tools, Platform-Tools and Command-line Tools. Then run `flutter doctor --android-licenses`.
3. Open PowerShell:
   ```powershell
   git clone https://github.com/<you>/scanpro-studio.git
   cd scanpro-studio
   flutter create --platforms=android --org com.scanprostudio --project-name scanpro_studio .
   python tool\configure_android.py      # needs Python 3 (py -3 tool\configure_android.py)
   flutter pub get
   flutter test
   flutter build apk --release --split-per-abi
   ```
4. The APKs are in `build\app\outputs\flutter-apk\`. To install over USB with debugging enabled: `flutter install` or `adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`.

### Commands
| Task | Command |
|---|---|
| Analyse | `flutter analyze` |
| All tests | `flutter test` |
| One test file | `flutter test test/print_layout_test.dart` |
| Debug run on a phone | `flutter run` |
| Release APKs | `flutter build apk --release --split-per-abi` |
| App bundle (Play) | `flutter build appbundle --release` (needs your own signing config) |

Repository tests use `sqflite_common_ffi` and need a native SQLite library: it's built into Windows/macOS. On Linux, install `libsqlite3-dev`.

PDF editor tests load the PDFium library that the `pdfium_dart` build hook downloads on the first `flutter test` (network needed once). They also use Poppler's `pdftotext` to check text as a standard viewer extracts it (`sudo apt-get install poppler-utils`; CI installs it).

---

## 5. Tests

| File | Covers |
|---|---|
| `test/print_layout_test.dart` | unit conversions, print-sheet geometry (capacity, centring, gaps, no overlap, never-shrink, manual grids, 4×6 orientation optimiser) |
| `test/pdf_test.dart` | merge/split/reorder/rotate/blank pages, AES-256 protect/unlock, text preservation, searchable PDF text layer, page sizes, sheet PDF physical size, calibration page, raster sheet pixel size + PNG/JPEG DPI metadata |
| `test/imaging_test.dart` | homography, warp, quad detection (+ fallback), blur metric, dHash duplicates, exposure flags, every filter preset, B&W thin-line preservation, Official mode keeps stamp colour, deskew sign/recovery, crop+rotate render, spine detection, spread split overlap, curved-page flattening |
| `test/text_and_models_test.dart` | entity extraction, classification, name suggestions, review flags (incl. Hindi), CSV tables, FTS query builder, naming, JSON/DB round trips, preset validation, page-range parsing |
| `test/repository_test.dart` | **acceptance tests**: original preserved after enhancement; OCR search finds a known word and the index follows edits/deletes/restores; batch order preserved and sessions recovered after restart; duplicates; trash; folders/tags; backup round trip; Hindi search |
| `test/widget_test.dart` | widget smoke tests |
| `test/pdf_editor_test.dart` | **PDF editor acceptance tests** on 10 fixture types (generated, embedded font, subset font, mixed styles, scanned, Hindi+English, multi-page, images/links/forms, password, 300 pages), text layout, edit model and undo/redo |
| `test/pdf_editor_widget_test.dart` | the editor workspace with the real PDFium worker: render, select, tools, page navigation, undo/redo, draft autosave, export |
| `test/ooxml_test.dart`, `test/conversion_test.dart` | DOCX/XLSX/PPTX writers and readers; **conversion acceptance tests 1–7 and 14** (validated with python-docx/openpyxl/python-pptx and LibreOffice when installed) |
| `test/conversion_jobs_test.dart` | **acceptance 8, 9, 13, 15**: batch jobs, passwords, OCR path, 200-page document, cancellation, recovery, validation, table review |
| `test/docsuite_services_test.dart`, `test/security_tools_test.dart` | **acceptance 9–12**: forms, links, annotations, bookmarks, headers/footers, protection, comparison, true redaction |
| `test/docsuite_widget_test.dart` | Conversion Centre, table review and reader screens |

Camera, ML Kit, biometrics and the print dialog need a real device. They're covered by the manual test checklist in `docs/TESTING.md`.

---

## 6. Privacy & permissions

| Permission | Why | When |
|---|---|---|
| `CAMERA` | Pro camera, portrait capture | first use |
| `USE_BIOMETRIC` | app lock / vault | only when enabled |
| ~~INTERNET~~ | **removed** from release builds (manifest `tools:node="remove"`) | n/a |

There's no storage or photo-library permission: imports use the Android Photo Picker and the system document picker, and exports use the Storage Access Framework. Documents live in app-private storage. Processed images contain no EXIF/GPS data. The "Smart scan" option runs inside Google Play services on-device. Play services may download or update that module itself.

**Encrypted PDF vs. encrypted app storage.** A password-protected PDF carries its encryption inside the file, so it stays protected wherever it goes. The vault encrypts documents inside the app with a device-bound key, which protects them at rest on this phone only. App lock only guards the app UI.

**Deletion.** Deleted files are removed from app storage. Flash storage can't guarantee secure erasure, and the app doesn't claim to shred files. Uninstalling the app or clearing its data destroys the vault key, so vault items can't be recovered after that.

---

## 7. Adding or changing photo presets

- **In the app:** Settings → Photo presets (or the tune icon in ID Photo Studio). Built-ins can be edited and reset. Custom presets take width/height (mm or inches), DPI, head-height range, top margin and background.
- **In code:** add a `PhotoPreset(...)` to `builtInPresets` in `lib/features/passport/photo_presets.dart`. Give it a unique `id`, and put the official source in `notes`. `validate()` enforces sane ranges.

## 8. Adding OCR languages

ML Kit supports Latin, Devanagari, Chinese, Japanese and Korean scripts. Each script model also reads Latin text. To add, for example, Japanese:
1. In `tool/configure_android.py`, add `implementation("com.google.mlkit:text-recognition-japanese:16.0.0")` to the dependency block (each model adds roughly 5–10 MB to the APK).
2. In `lib/features/ocr/ocr_service.dart`, add an `OcrScript('japanese', 'Japanese', '…')` and map it to `TextRecognitionScript.japanese` in `_recognizer`.
3. Run `flutter test` and test on a device.

Scripts that ML Kit doesn't support (Tamil, Bengali, Gujarati, …) would need a different engine such as Tesseract via a native plugin. That isn't included.

---

## 9. Known limitations

- **Build status:** see `docs/BUILD_STATUS.md` for the latest CI results.
- **PDF editor:** see the limitations in `docs/PDF_EDITOR.md` §5 (Hindi shaping, font embedding size, reflow scope).
- **Conversions and document tools:** see `docs/DOCUMENT_SUITE.md` §7 (Office layout fidelity, table detection, rotated pages, jobs stop if Android kills the app).
- Pure-Dart processing of 20+ MP photos takes roughly 1–4 s per page on mid-range phones. Processed pages are capped at 2800 px by default (configurable), and originals keep full resolution.
- Smart scan needs Google Play services. Without it, use the Pro camera.
- Curved-page flattening is approximate (see Book mode).
- Background replacement can struggle with fine hair, transparent glasses, or clothing in the same colour as the background. Always use the side-by-side preview and the refine brush.
- OCR confidence values depend on the plugin version. When they're missing, uncertainty flags are heuristic.
- The older PDF tools (Organise, Merge, Split) don't carry over form fields, links or annotations of the source pages. The PDF editor's page tools do preserve them.
- Very large documents (hundreds of pages) are assembled in memory by the PDF library. Export in parts if memory is tight.
- APKs are signed with a debug key.

## 10. Roadmap

- **iOS:** the architecture is platform-neutral (Flutter, ML Kit has iOS builds, sqflite/printing/local_auth support iOS). Remaining work: generate `ios/`, add camera/photo/Face ID usage strings, replace the Android-only document scanner with VisionKit `VNDocumentCameraViewController` through a small platform channel, and set up signing.
- **Play Store release:** own signing key, R8 keep-rules for ML Kit, privacy policy page, AAB build.
- **Optional, opt-in only:** WebDAV backup, an on-device LLM for summaries, Tesseract for more Indic scripts, OpenCV for faster processing of very large images.
