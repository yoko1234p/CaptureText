# CaptureText

[**English**](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![CaptureText banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.9.0--preview.1-7d9cfa?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**Take useful text from your screen.** A standalone project in the personal macOS tools collection.

## What it does

- Recognize a selected screen region or imported image with on-device OCR.
- Read text aloud, scan QR codes and review tables before CSV/XLSX export.
- Use macOS Continuity Camera for photos and scans when a compatible device is available.

## Install a preview

Download the macOS ZIP from [Releases](https://github.com/yoko1234p/CaptureText/releases/tag/v0.9.0-preview.1), unzip, and move `CaptureText.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

## Build from source

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The required local `Shared/` packages and build helpers are included. Building does not install or launch the app.

## Requirements and limits

macOS 14+; Xcode 27/Swift 6 and Python 3 for source builds. Screen capture needs Screen Recording permission; file OCR does not. Continuity Camera depends on nearby compatible devices, account and network conditions. Review OCR and table structure before relying on exported data.

## Contribute and license

Original application code is GPL-3.0-only. Keep bundled third-party and data notices; see [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
