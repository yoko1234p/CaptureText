# CaptureText

[English](README.md) · [**繁體中文**](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![CaptureText banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.9.0--preview.1-7d9cfa?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**從畫面擷取可用文字。** 個人 macOS 工具系列的獨立 App。

## 主要功能

- 用本機 OCR 識別框選畫面或匯入圖片。
- 朗讀文字、掃描 QR 碼，並在匯出 CSV/XLSX 前校對表格。
- 有兼容裝置時可使用 macOS 接續互通相機拍照或掃描。

## 安裝預覽版

從 [Releases](https://github.com/yoko1234p/CaptureText/releases/tag/v0.9.0-preview.1) 下載 macOS ZIP，解壓後將 `CaptureText.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

## 從原始碼建置

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

所需的本機 `Shared/` 套件和建置工具已包含在 repo；建置不會自動安裝或啟動 App。

## 系統要求與限制

macOS 14 或以上；原始碼建置需 Xcode 27／Swift 6 和 Python 3。 擷取畫面需要螢幕錄製權限；圖片檔 OCR 不需要。接續互通相機視乎附近裝置、帳戶及網絡條件。使用表格匯出資料前請校對。

## 參與及授權

原創 App 程式碼以 GPL-3.0-only 發布；附帶的第三方及資料授權須各自保留。詳見 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
