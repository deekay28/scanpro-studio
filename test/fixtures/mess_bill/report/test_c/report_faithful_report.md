# Visual comparison: report_faithful

- Pages: source 2, output 2 (match)
- Page sizes (pt): source [(595.0, 842.0), (595.0, 842.0)], output [(595.304, 841.89), (595.304, 841.89)] (match)
- DOCX: 2 picture(s), 0 text run(s), 0 table(s)

## Page 1

- SSIM 0.9791, mean absolute difference 2.9, pixels differing by >25%: 1.3%
- OCR words: source 51, output 52, matched 49 (recall 0.961, precision 0.942)
- Word displacement (pt): median 0.36, 90th percentile 0.8, max 1.53
- Largest displacements: "region" 1.5 pt, "report" 1.3 pt, "page" 1.1 pt, "1,200" 1.0 pt, "focused" 0.8 pt, "145,000.00" 0.8 pt, "annual" 0.8 pt, "year." 0.8 pt
- Images: `report_faithful_p1_side_by_side.png`, `report_faithful_p1_heatmap.png`

## Page 2

- SSIM 0.9956, mean absolute difference 1.49, pixels differing by >25%: 0.3%
- OCR words: source 18, output 15, matched 14 (recall 0.778, precision 0.933)
- Word displacement (pt): median 0.51, 90th percentile 0.72, max 1.08
- Largest displacements: "page" 1.1 pt, "annual" 0.7 pt, "date" 0.5 pt, "15/03/2024" 0.5 pt, "amount" 0.5 pt, "expenses" 0.5 pt, "paper" 0.5 pt, "28/03/2024" 0.5 pt
- Images: `report_faithful_p2_side_by_side.png`, `report_faithful_p2_heatmap.png`
