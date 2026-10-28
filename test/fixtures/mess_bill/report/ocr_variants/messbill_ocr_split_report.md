# Visual comparison: messbill_ocr_split

- Pages: source 1, output 1 (match)
- Page sizes (pt): source [(595.276, 841.89)], output [(595.304, 841.89)] (match)
- DOCX: 3 picture(s), 195 text run(s), 2 table(s)

## Page 1

- SSIM 0.6725, mean absolute difference 53.35, pixels differing by >25%: 22.4%
- OCR words: source 100, output 96, matched 87 (recall 0.87, precision 0.906)
- Word displacement (pt): median 2.52, 90th percentile 11.97, max 171.73
- Largest displacements: "amount" 171.7 pt, "off" 156.6 pt, "type" 53.7 pt, "payable" 29.5 pt, "rounded" 28.8 pt, "cyber" 25.2 pt, "basic" 20.9 pt, "security-09" 12.3 pt
- Images: `messbill_ocr_split_p1_side_by_side.png`, `messbill_ocr_split_p1_heatmap.png`
