# Application icon

`AppIcon-source.png` was generated with the built-in `image_gen` tool for Docling Mac. `scripts/make-icon.swift` packages this source into the standard macOS rounded tile and iconset sizes; it does not substitute a programmatically drawn document.

Final generation prompt:

> Use case: logo-brand. One square macOS application icon source image for a minimal offline document converter named Docling Mac. FULL BLEED SQUARE image, completely opaque solid warm ivory background filling every edge and corner; no border, no frame, no transparent pixels, no exterior shadow, no rounded-square tile. In the center is a single beautiful deep forest teal green document in restrained soft 3D relief with a curled folded top-right corner, three bold ivory horizontal text grooves, and one subtle cream paper sheet behind it. Clear strong silhouette designed to stay legible at tiny icon sizes. Minimal, quiet, premium Apple native utility style. Straight-on orthographic view, no perspective tilt. Document occupies central 65 percent of square. Soft restrained material shading only around document. No words or letters, no watermark, no sparkle, no robot, no photographs, no surrounding UI. The application build system will apply its standard macOS rounded-square icon mask to this full-bleed square source.

## Liquid Glass icon (v0.4)

`AppIcon.icon/` is the editable Apple Icon Composer source. `Assets/Document.png` was edited from the original generated icon with the built-in `image_gen` tool. The original source stays intact, and the package also includes a traditional `.icns` compatibility icon. Older macOS may use a flattened rendition from the catalog. The transparent foreground and native warm ivory background are composed by `actool`; the system supplies glass lighting, shadows, dark and tinted renditions. No icon cache or system appearance settings are modified.

Final edit prompt (built-in image generation, transparent background):

> Edit this icon foreground. Remove the cream backing sheet entirely. Keep ONLY the single green front document, its folded upper-right corner, and its three cream horizontal grooves. Keep original size and position on square canvas. Everything outside that single green front document must be fully transparent with a pristine clean antialiased silhouette. Remove ALL floating speckles, ragged edges, white/cream fragments around the outside, and cast shadows. Preserve the green document and its 3 cream grooves exactly. No new backdrop or new elements. This is a clean production icon layer.

The manifest follows Apple's [Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) and [Landmarks sample](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass). Open `AppIcon.icon` in Icon Composer to edit its material. `scripts/build.sh` compiles `Assets.car`, merges the compiler's icon metadata and retains the original `.icns` fallback.
