# App icon — Stack

The chosen mark is **Stack**: three fanned, color-banded profile cards (teal, amber, violet) on a charcoal squircle, representing isolated browser profiles.

## Source of truth

- `icon.svg` — the master 1024×1024 icon, used to render 64px and above. Full detail: gradients, glossy sheen, avatar+text motif on the front card.
- `icon-small.svg` — a hand-simplified variant used only for 16px and 32px renders. At those sizes the avatar dot, text bars, and gradients turn to mud, so this variant swaps in flat colors and a wider card fan for a clean silhouette. This is standard macOS practice (small sizes get a simplified icon, not just a scaled-down one).
- `AppIcon.iconset/` — the 10 rendered PNGs macOS expects, generated from the two SVGs above via Playwright (Chrome headless, `omitBackground: true` for real alpha transparency outside the squircle).
- `AppIcon.icns` — built from `AppIcon.iconset/` with `iconutil`. This is the file the Xcode project / app bundle should reference.

`concept-1.svg` … `concept-4.svg` and `preview.html` are the earlier exploration deliverables, kept for reference; they are not part of the shipped icon.

## Regenerating

If `icon.svg` or `icon-small.svg` change, re-render the iconset and rebuild the `.icns`:

```bash
# Render AppIcon.iconset/*.png from icon.svg / icon-small.svg
# (see the Playwright render script used to produce the current PNGs —
#  16px and 32px targets source icon-small.svg, 64px+ source icon.svg)

# Then rebuild the icns:
cd assets/branding
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

`iconutil` requires `AppIcon.iconset` to contain exactly the 10 standard file names (`icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`, `icon_32x32@2x.png`, `icon_128x128.png`, `icon_128x128@2x.png`, `icon_256x256.png`, `icon_256x256@2x.png`, `icon_512x512.png`, `icon_512x512@2x.png`).
