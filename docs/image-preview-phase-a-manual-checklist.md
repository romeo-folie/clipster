# Image Preview — Phase A Manual Checklist

Branch: `feat/image-preview-phase-a1`

## Scope
- Image rows in clipboard panel show thumbnail instead of generic image icon when thumbnail data is available.
- Fallback icon remains for decode failure / missing data.
- Lazy load only on row appearance.

## Test Steps
1. Launch Clipster app and daemon.
2. Copy a regular text snippet.
3. Copy an image from Preview/Safari/Slack.
4. Open Clipster panel (`⌘⇧V`).
5. Confirm the image entry shows a thumbnail in the left icon slot.
6. Confirm text entries still show existing icons and layout is unchanged.
7. Scroll up/down through mixed entries and verify no obvious stutter/jank.
8. Trigger a decode-failure case (e.g., stale image row with missing/corrupt thumbnail data if available) and verify fallback image icon is shown.

## Expected Results
- Thumbnail appears for image entries.
- Non-image rows unaffected.
- Row height and spacing remain stable.
- Missing/invalid thumbnail bytes do not crash UI; fallback icon is shown.
