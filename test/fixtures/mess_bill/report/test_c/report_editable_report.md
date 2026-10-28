# Visual comparison: report_editable

- Pages: source 2, output 2 (match)
- Page sizes (pt): source [(595.0, 842.0), (595.0, 842.0)], output [(595.304, 841.89), (595.304, 841.89)] (match)
- DOCX: 1 picture(s), 130 text run(s), 1 table(s)

## Page 1

- SSIM 0.9527, mean absolute difference 3.41, pixels differing by >25%: 1.7%
- OCR words: source 51, output 53, matched 48 (recall 0.941, precision 0.906)
- Word displacement (pt): median 0.72, 90th percentile 3.22, max 4.68
- Largest displacements: "units" 4.7 pt, "1,200" 4.5 pt, "38,250.50" 4.1 pt, "south" 3.4 pt, "revenue" 3.2 pt, "report" 2.2 pt, "region" 1.9 pt, "new" 1.4 pt
- Images: `report_editable_p1_side_by_side.png`, `report_editable_p1_heatmap.png`

## Page 2

- SSIM 0.9907, mean absolute difference 0.78, pixels differing by >25%: 0.4%
- OCR words: source 18, output 19, matched 16 (recall 0.889, precision 0.842)
- Word displacement (pt): median 0.72, 90th percentile 1.8, max 11.52
- Largest displacements: "page" 11.5 pt, "of" 1.8 pt, "expenses" 1.1 pt, "paper" 1.1 pt, "toner" 1.1 pt, "amount" 0.7 pt, "annual" 0.7 pt, "report" 0.7 pt
- Images: `report_editable_p2_side_by_side.png`, `report_editable_p2_heatmap.png`
