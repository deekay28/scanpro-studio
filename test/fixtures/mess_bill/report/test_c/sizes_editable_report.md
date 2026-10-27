# Visual comparison: sizes_editable

- Pages: source 3, output 3 (match)
- Page sizes (pt): source [(595.28, 841.89), (595.28, 419.53), (612.0, 792.0)], output [(595.304, 841.89), (595.304, 419.556), (612.0, 792.0)] (match)
- DOCX: 0 picture(s), 19 text run(s), 0 table(s)

## Page 1

- SSIM 0.9967, mean absolute difference 0.28, pixels differing by >25%: 0.1%
- OCR words: source 4, output 4, matched 4 (recall 1.0, precision 1.0)
- Word displacement (pt): median 1.08, 90th percentile 1.08, max 1.08
- Largest displacements: "portrait" 1.1 pt, "page" 1.1 pt, "in" 1.1 pt, "a4" 0.7 pt
- Images: `sizes_editable_p1_side_by_side.png`, `sizes_editable_p1_heatmap.png`

## Page 2

- SSIM 0.9929, mean absolute difference 0.62, pixels differing by >25%: 0.3%
- OCR words: source 4, output 4, matched 4 (recall 1.0, precision 1.0)
- Word displacement (pt): median 1.08, 90th percentile 1.44, max 1.44
- Largest displacements: "landscape" 1.4 pt, "page" 1.1 pt, "in" 1.1 pt, "a5" 0.4 pt
- Images: `sizes_editable_p2_side_by_side.png`, `sizes_editable_p2_heatmap.png`

## Page 3

- SSIM 0.9972, mean absolute difference 0.22, pixels differing by >25%: 0.1%
- OCR words: source 3, output 3, matched 3 (recall 1.0, precision 1.0)
- Word displacement (pt): median 1.08, 90th percentile 1.44, max 1.44
- Largest displacements: "letter" 1.4 pt, "page" 1.1 pt, "in" 1.1 pt
- Images: `sizes_editable_p3_side_by_side.png`, `sizes_editable_p3_heatmap.png`
