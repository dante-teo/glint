# Devin Real Animated Portrait Assets

This folder contains the tracked source strips used to build Devin's animated
portrait logo assets.

## Source Strips

`strips/*.png` are horizontal 8-frame strips, one per Devin state:

- `idle.png`
- `thinking.png`
- `tool.png`
- `compressing.png`
- `permission.png`
- `done.png`
- `failed.png`

Keep these files checked in. The generated review output under
`design/devin-real-animated/` is intentionally ignored and can be recreated.

## Regenerating Assets

Run:

```sh
python3 scripts/generate_devin_portrait_icons.py
```

The script writes the APNG datasets in `Glint/Resources/Assets.xcassets/`,
updates the static Devin mark images, and creates QA artifacts in
`design/devin-real-animated/qa/`.

Review `design/devin-real-animated/qa/contact-sheet.png` and the preview GIFs
under `design/devin-real-animated/qa/previews/` after regenerating.

## Strip Requirements

- Use a flat chroma green background so the generator can remove it cleanly.
- Keep each strip to exactly 8 animation frames.
- Preserve the state filenames above; the generator maps them to app assets.
- Keep Devin face-first and neck-up. The white blazer should not be the identity
  anchor because it is mostly cropped out in the final mark.
- Prefer redrawn animation frames over a static portrait with visual effects.

