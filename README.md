# CaptureText

Recognize text from the screen and images using on-device macOS OCR.

**文字與筆記系列：框選取字、圖片 OCR、朗讀與表格整理。** Interfaces support English, Traditional Chinese and Simplified Chinese.

## Features

- Capture a screen region, reopen the last region, or import an image.
- Preserve/merge lines, accumulate text, read it aloud and recognize QR/barcodes.
- Import photos/scans through macOS Continuity Camera.
- Review table recognition and export structured data as CSV/XLSX.

## Build and test

Requires macOS 14+, Xcode 27/Swift 6 and Python 3. This repository includes its required shared packages; keep `Shared/` and `scripts/` beside `DeskTools/`.

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The historical package directory is named `DeskTools`, but this repository includes only CaptureText and its required shared modules/tests. The app bundle is written to `DeskTools/dist/CaptureText.app`. Building does not install or launch it. See [SIGNING.md](SIGNING.md) for ad-hoc development and your own signing identity.

## Use and limitations

Screen capture requires screen-recording access; image-file OCR does not. Continuity Camera requires compatible nearby devices and Apple's account/network conditions. Available recognition languages come from the installed macOS Vision framework. OCR and table structure require review for small text, complex columns and low-quality images.

## Development and license

This app is under active development. Report the macOS version, reproduction steps and actual validation results with changes. Use synthetic data for file, clipboard and permission tests. Validate interface catalogs from the repository root with `python3 scripts/localization/check-catalogs.py`.

Original maintained code is **GPL-3.0-only**. Keep the separate dependency/data notices listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
