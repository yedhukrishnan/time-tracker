# Icon Composer layers

Source layers for building `AppIcon.icon` (macOS 26 layered icon format).

- `glyph.png` — crosshair glyph, extracted from the legacy 1024px app icon
- Background fill: `#4F46E5` (indigo)
- Glyph accent (center dot): `#A5B4FC`

Build: open Icon Composer (Xcode → Open Developer Tool → Icon Composer),
new macOS icon → set background fill to #4F46E5 → add glyph.png as a layer.
Save as `AppIcon.icon` in the repo root, add to the Xcode project.
The name must match the asset catalog icon (`AppIcon`) so Tahoe uses the
.icon and older macOS falls back to the .icns from Assets.xcassets.
