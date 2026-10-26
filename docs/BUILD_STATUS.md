# Build & test status

Results from real runs (GitHub Actions, Flutter 3.47.8 stable, Ubuntu runner) and a local Linux run of the same Flutter version.

| Item | Result |
|---|---|
| Compiled by Flutter (`flutter build apk --release`, universal + per-ABI) | ✅ CI run #8 (v1.0.8, document suite): all four APKs built |
| `flutter analyze` | ✅ no errors or warnings (7 infos in older code) |
| `flutter test` | ✅ 134 / 134 passed in CI run #8; 135 / 135 locally (adds acceptance test 14, which also uses LibreOffice locally) |
| PDFium packaged in the APK | ✅ `lib/arm64-v8a/libpdfium.so` (6.4 MB) present in the release APK |
| Release permissions (`aapt dump permissions`) | ✅ see `permissions.txt` in each release; INTERNET is removed; v1.0.8 has the same permissions as v1.0.7 (flutter_tts added none) |
| On-device manual tests (`docs/TESTING.md`, incl. Workflow G: PDF editor) | ⏳ not run: needs a physical phone |

## Document suite acceptance tests
All 15 passed; details in `docs/DOCUMENT_SUITE.md` §6. On-device checks (Workflows H and I in `docs/TESTING.md`) have not been run.

## PDF editor acceptance tests (automated, actual results)
All passed. See `docs/PDF_EDITOR.md` §7 for what each test checks.

| # | Fixture | Result |
|---|---|---|
| 1 | Digitally generated PDF, unembedded Helvetica, scaled text matrix | ✅ |
| 2 | Fully embedded TrueType font | ✅ |
| 3 | Subset font | ✅ |
| 4 | Mixed font sizes and colours | ✅ |
| 5 | Scanned image-only page (OCR layer, cover, replacement) | ✅ |
| 6 | Hindi + English | ✅ (with the expected Devanagari shaping warning) |
| 7 | Multi-page with header/footer; reorder/delete/rotate/blank/page numbers/extract | ✅ |
| 8 | Images, links, form fields; inserted photo/signature/annotations/stamp; flatten | ✅ |
| 9 | AES-256 password-protected PDF | ✅ |
| 10 | 300-page PDF | ✅ |
| + | Paragraph reflow, move keeps line and baseline, style-only change keeps line breaks | ✅ |
| UI | Editor workspace with the real PDFium worker | ✅ |
