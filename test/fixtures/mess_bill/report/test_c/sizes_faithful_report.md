# Visual comparison: sizes_faithful

- Pages: source 3, output 3 (match)
- Page sizes (pt): source [(595.28, 841.89), (595.28, 419.53), (612.0, 792.0)], output [(595.304, 841.89), (595.304, 419.556), (612.0, 792.0)] (match)
- DOCX: 3 picture(s), 0 text run(s), 0 table(s)

## Page 1

- SSIM 0.9992, mean absolute difference 1.1, pixels differing by >25%: 0.1%
- OCR words: source 4, output 4, matched 4 (recall 1.0, precision 1.0)
- Word displacement (pt): median 0.51, 90th percentile 0.51, max 0.51
- Largest displacements: "page" 0.5 pt, "a4" 0.5 pt, "in" 0.4 pt, "portrait" 0.0 pt
- Images: `sizes_faithful_p1_side_by_side.png`, `sizes_faithful_p1_heatmap.png`

## Page 2

- SSIM 0.9982, mean absolute difference 1.24, pixels differing by >25%: 0.2%
- OCR words: source 4, output 4, matched 4 (recall 1.0, precision 1.0)
- Word displacement (pt): median 0.51, 90th percentile 0.72, max 0.72
- Largest displacements: "landscape" 0.7 pt, "page" 0.5 pt, "a5" 0.5 pt, "in" 0.4 pt
- Images: `sizes_faithful_p2_side_by_side.png`, `sizes_faithful_p2_heatmap.png`

## Page 3

- SSIM 0.9993, mean absolute difference 1.08, pixels differing by >25%: 0.1%
- OCR words: source 3, output 3, matched 3 (recall 1.0, precision 1.0)
- Word displacement (pt): median 0.36, 90th percentile 0.36, max 0.36
- Largest displacements: "page" 0.4 pt, "in" 0.4 pt, "letter" 0.4 pt
- Images: `sizes_faithful_p3_side_by_side.png`, `sizes_faithful_p3_heatmap.png`
