# Visual comparison: messbill_ocr_split

- Pages: source 1, output 1 (match)
- Page sizes (pt): source [(595.276, 841.89)], output [(595.304, 841.89)] (match)
- DOCX: 3 picture(s), 188 text run(s), 2 table(s)

## Page 1

- SSIM 0.6753, mean absolute difference 53.27, pixels differing by >25%: 22.3%
- OCR words: source 100, output 94, matched 86 (recall 0.86, precision 0.915)
- Word displacement (pt): median 2.55, 90th percentile 11.97, max 171.74
- Largest displacements: "amount" 171.7 pt, "off" 156.6 pt, "type" 53.7 pt, "payable" 29.2 pt, "rounded" 28.1 pt, "pos" 24.2 pt, "through" 21.6 pt, "card" 21.2 pt
- Images: `messbill_ocr_split_p1_side_by_side.png`, `messbill_ocr_split_p1_heatmap.png`
