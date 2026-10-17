# Docling Mac

**English** | [简体中文](README.zh-CN.md)

[![macOS CI](https://github.com/superjackche/docling-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/superjackche/docling-mac/actions/workflows/ci.yml)
[![LINUX DO](https://img.shields.io/badge/LINUX%20DO-Community-FFB003)](https://linux.do/)

A minimal, native macOS app for converting documents with [Docling](https://github.com/docling-project/docling). Drop files or folders, preview the results, and automatically save Markdown, HTML, and Docling JSON—all processed on your Mac.

[Download](https://github.com/superjackche/docling-mac/releases/latest) · [Performance](docs/PERFORMANCE.md) · [Acceptance checks](docs/ACCEPTANCE.md)

An independent, unofficial client built with SwiftUI and AppKit, with no third-party Swift packages. The client is [MIT licensed](LICENSE).

## Install and use

Requires **Apple Silicon (M-series) and macOS 14+**. The pinned engine does not support Intel Macs. macOS 26+ uses native Liquid Glass; macOS 14/15 uses compatible native controls. The app supports English and Simplified Chinese and follows your preferred language list by default; English is used when neither language matches. Choose **Follow system / English / 简体中文** in **Settings → Language** (`⌘,`). Quit and reopen the app to apply a change to the interface, menus, and system dialogs. Let running tasks finish before quitting.

Download the DMG from [GitHub Releases](https://github.com/superjackche/docling-mac/releases/latest) and drag the app into Applications, or extract the ZIP. The package contains only the roughly 6 MB client; the processing environment and models are downloaded separately during setup.

The public build is ad-hoc signed and has **not been notarized with Developer ID**. macOS may block the first launch. After checking the source, follow [Apple's instructions](https://support.apple.com/102445) to allow it in **System Settings → Privacy & Security**.

1. Install [uv](https://docs.astral.sh/uv/getting-started/installation/): `brew install uv`.
2. Open `Docling Mac.app` and click **Prepare local engine**. The app installs the pinned Python 3.12 environment and dependencies.
3. Drop files or folders, or press `⌘O` to select them. Conversion starts automatically.
4. Review the preview. Results are saved automatically to `~/Docling_Mac/`. Click **Open result** for the selected document or **Results folder** in the toolbar for all results. You can also copy Markdown directly.

The whole content area accepts drops, including the list, preview, and empty space. A window-wide highlight and drop prompt appear while dragging.

Supported inputs: **PDF, DOCX, PPTX, XLSX, HTML, Markdown, CSV**, and **PNG, JPEG, TIFF, BMP, WebP**. Scans use Apple OCR for Chinese and English. Images are embedded in the output. Partial successes and failures are reported explicitly, with manual retry available.

PDF and image processing require an initial online download of layout and table models. You can prepare these in **Engine & models**. Setup verifies that models actually load offline; conversion always uses Hugging Face offline mode. The app looks for uv in `~/.local/bin/uv`, `/opt/homebrew/bin/uv`, or `/usr/local/bin/uv`. The environment and models use about **1.6 GB**, with additional download cache space needed during installation.

App-generated controls, queue states, and messages are localized. Raw engine logs and third-party diagnostic messages retain their original language. Language selection does not change OCR languages or document content.

## Liquid Glass

The app uses the system `NavigationSplitView` glass sidebar, native toolbar groups, glass action buttons, and drop feedback. The sidebar is collapsible; document previews and logs retain solid backgrounds for readability. No blur layers are added to document rows or large document bodies.

Native controls follow system transparency and motion preferences. Custom feedback uses solid backgrounds and clear borders when Reduce Transparency or Increase Contrast is enabled. Accent colors adapt to light and dark appearance. There are no custom animation timers or background rendering loops.

The icon uses Apple Icon Composer's layered format: an AI-generated transparent paper foreground is separated from the system background, allowing the system to render lighting, shadows, and dark/tinted appearances. A traditional `.icns` is also provided. See [icon sources and prompts](Assets/README.md).

## Batch processing and resource use

- Each batch starts one conversion process and loads the converter once. Files are processed sequentially, with CPU inference parallelism of 2, 2 PDF parser threads, a pipeline batch size of 2, and a queue size of 4. Docling and Apple OCR may create additional internal threads; these settings are not a system-wide thread limit.
- Python and models are released after each batch. There is no resident engine, listening port, or periodic polling. Import, preview loading, and saving run in the background; the main thread handles the UI. Files added during processing are handled in the next batch.
- Reimporting a file with the same path, size, and modification time moves its existing entry to the top and selects it. The reuse notice lasts 4 seconds before returning to the completed state. Identical content at different paths can reuse results via streaming SHA-256. Changes to content, extension, OCR settings, engine lock, backend code, configuration, or model identity invalidate the cache.
- The result cache defaults to **512 MiB and 14 days**. Results referenced by the current queue are retained temporarily and may exceed the limit; clearing the queue or exiting trims the cache. Clearing the queue, exiting, or cleaning the cache never deletes permanent results in `~/Docling_Mac/`. The queue is not restored after quitting.
- Previews have a **100 MiB limit** (shown as 100 MB in the app). Only the selected HTML or Markdown view is loaded; switching views cancels the previous read. Oversized HTML uses a limited text preview while the complete output stays on disk. Markdown uses a native text view with on-demand layout. The limit applies to reading, not to WebKit's total rendering memory.
- Results are saved sequentially in the background, copying 1 MiB at a time. Reused JSON results recover each input's own source filename. All three formats are staged in a hidden temporary directory and published together only after successful writes. Save failures are shown explicitly; **Retry save** does not require reconversion.
- Conversion starts after import. **Resume processing** appears only after a manual stop; files added while stopped wait for you to continue. Retrying starts processing automatically. Closing the window leaves the current task running. Quitting waits for the conversion process group to stop, cancels imports and obsolete preview reads, finishes saving completed documents, and then clears temporary files. A save failure cancels quitting and preserves viewable results. Failed work is not retried automatically, and incomplete results are not cached for reuse.

Runtime settings are in [Backend/runtime.json](Backend/runtime.json); rebuild after editing them. See [performance measurements and conditions](docs/PERFORMANCE.md).

## Output folders

Each output directory keeps the original filename, including its extension, so similarly named PDF and Word files remain distinguishable:

```text
~/Docling_Mac/
  report.pdf/
    document.md
    document.html
    document.json
  report.pdf (2)/
    ...
```

The same source and conversion result reuse an existing directory. Different sources with the same filename, changed content, or changed conversion settings receive numbered directories, preserving previous results.

Each directory contains a hidden `.docling-result.json` receipt identifying the saved output. You may rename the directory in Finder; the app recognizes it through the receipt on its next launch. Keep the receipt. If an output format has been removed, the app creates a new complete directory without overwriting the remaining files.

## Engine and upstream updates

The app uses a fully locked dependency set tested with the client and does not upgrade it in the background. Settings let you check upstream PyPI versions, open release notes, repair the pinned environment, or reverify existing models. Checking for updates only queries versions; it does not install anything. Reverification of verified models stays offline.

Maintainers updating the engine should edit `Backend/pyproject.toml` and `Backend/uv.lock`, run format and batch regressions, prepare and verify models again, and then release the client. A changed lock requires engine preparation again; cached results from the old engine are not mixed with new output.

## Privacy and data

- Documents are processed in a local Python subprocess. No account, cloud parsing API, or app telemetry is used.
- Installation contacts Python/PyPI download sources; model preparation contacts Hugging Face. Manual update checks contact PyPI.
- Docling remote services and external plugins are disabled. Only local files are accepted. External images in HTML and Markdown are not downloaded proactively.
- In-app previews disable JavaScript and use CSP to block network resources. Saved HTML also includes CSP.
- Source files are never modified. Automatic saving does not overwrite existing files or directories.
- **Permanent results:** `~/Docling_Mac/`. These are not automatically cleaned; manage them in Finder.
- **Environment and models:** `~/Library/Application Support/Docling Mac/`.
- **Result cache:** `~/Library/Caches/Docling Mac/Results/`, containing converted document content. Session temporary results are cleaned on normal exit. Logs may contain file paths; review them before sharing.

Extraction quality depends on Docling and Apple OCR. Review complex formulas, multipage tables, and scans. The app currently supports standard document parsing, without VLM, audio/video, or cloud services.

## Build and test

Building requires **macOS 26+ and Xcode 26+ / macOS 26+ SDK** for Liquid Glass APIs and Icon Composer assets. The minimum runtime remains macOS 14. Command Line Tools alone do not include the icon compiler. Set `DEVELOPER_DIR` to use an installed Xcode without changing the global `xcode-select` setting.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh
open 'dist/Docling Mac.app'
```

Run `./scripts/package.sh` to build locally and generate a DMG, ZIP, and SHA-256 checksums. The DMG includes an Applications shortcut. No signing credentials are included in the repository.

After preparing the engine in the app, run:

```sh
./scripts/test.sh
"$HOME/Library/Application Support/Docling Mac/runtime/bin/python3" scripts/verify-engine.py
```

For headless setup, run `./scripts/prepare-engine.sh` first. GitHub Actions uses ARM64 runners and Xcode 26.3: macOS 15 prepares the locked environment, runs Swift and Python checks, downloads and verifies models offline, and converts six real formats. macOS 26 builds and validates the packages and launches the native window; the same package is then downloaded on macOS 15 to verify signing and window launch. CI runs on `main` pushes, pull requests, version tags, and manual dispatches. Results and packages are retained as CI artifacts.

Tests cover queue behavior, process cancellation, cache invalidation, concurrency exclusion, model verification, and real formats. See [acceptance scope and results](docs/ACCEPTANCE.md). Supporting documents linked here are currently in Chinese.

## License and acknowledgments

The client is [MIT licensed](LICENSE). Third-party packages and models retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). AI-generated icon artwork and prompts are documented in [Assets/README.md](Assets/README.md).

Docling belongs to the upstream project. This app is independent and is not an official product of the Docling project.
