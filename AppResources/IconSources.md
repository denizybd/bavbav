# Bavbav v3 icon sources

2026-09-09. Existing B / terminal / mint identity retained. The user requested
native macOS rounded icons with a white light appearance and a near-black dark
appearance. Artwork was edited with the built-in `image_gen` tool, not the API
CLI. No external trademark artwork was used.

## Saved assets

- `BavbavArtwork-v3-light.png`: final light artwork master.
- `BavbavArtwork-v3-dark.png`: final dark artwork master.
- `BavbavIcon-v3-light.png`: native-masked 1024px RGBA runtime asset.
- `BavbavIcon-v3-dark.png`: native-masked 1024px RGBA runtime asset.
- `Bavbav-v3.iconset/`: 10 scale-specific native RGBA images.
- `Bavbav-v3.icns`: signed-bundle fallback icon (light).

The first transparent-background edit produced opaque checkerboard pixels.
It was rejected as a shipping asset. The final artwork is deliberately full-bleed;
`scripts/PrepareAppIcons.swift` applies an identical native rounded mask and
100px transparent inset on a 1024px canvas. Generated artwork is never trusted
to contain transparency merely because its preview looks transparent.

Original edit target: `AppResources/BavbavIcon-v2.png`, retained unchanged.
The final two edits used the intermediate B/tile design as a composition
reference. The tool-generated originals remain in Codex's generated image store;
the app references only copies stored in this repository.

## Final prompt set

Common prompt, used verbatim for each final edit:

> Use case: precise-object-edit. Image 1 is the edit target, the existing Bavbav B monogram and terminal chevron/underscore icon. Make a full-bleed SQUARE ARTWORK MASTER for a macOS application icon. This is artwork only; our native macOS asset packager will apply rounded corners and transparent padding afterward. Remove the ENTIRE checkerboard and crop away ALL exterior margins; the dark rounded tile in the reference must become an edge-to-edge square surface. Absolutely NO checkerboard, transparency pattern, border margin, rounded outer shape, presentation/mockup or perspective. Preserve the centered layered B monogram, the mint green stacked accent, and the exact >_ terminal motif. B emblem should occupy roughly 68 percent of canvas width and 68 percent height, centered. Simple high quality and understated, no glow or extraneous text. Output one square PNG.

Dark suffix:

> DARK APPEARANCE: continuous very dark graphite background (#111318) reaches ALL FOUR canvas edges and corners. B face in slightly lighter graphite, preserved bright mint accent. Change only the exterior framing from the reference; keep emblem identity and geometry.

Light suffix:

> LIGHT APPEARANCE: clean pearl WHITE background (#F5F6F8) reaches ALL FOUR canvas edges and corners. B face near-black graphite for clear contrast; preserve the same mint green accent and terminal motif. No black tile behind the B. Change the surface color from dark to white, keep emblem identity, proportions and geometry identical.

## Verification boundary

Artwork checks inspect alpha, dimensions, occupied area, white/dark backgrounds,
and contrast at 16/32/64px. Controller checks exercise real process-local AppKit
appearance observation with an injected image publisher. They do not change the
user's system theme, foreground app, or actual Dock icon. Live Cmd-Tab and any
third-party AltTab cache behavior are separate from these checks.
