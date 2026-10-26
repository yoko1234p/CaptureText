# CaptureText v0.10.0-preview.1

## English

- Preserve raw OCR URL whitespace, punctuation and tokens; formatting suggestions require explicit review.
- Add Precision Review, reread of the last owned crop, editable candidates and changed-span highlighting. Cancellation and stale results cannot change the clipboard; additive rereads replace the last segment once.
- Add optional local PaddleOCR models via a native ONNX worker, with verified downloads, bounded input, a timeout and process exit after each request. Apple Silicon only for this optional pack.
- Add manual three-frame video rereading with display checks and changed-subtitle rejection.
- Recover gracefully when automatic language detection returns a region too thin for Vision.
- English, Traditional Chinese and Simplified Chinese UI and documentation; independent fixture splits and release-mode OCR evaluation.

Automatic replacement is disabled. Synthetic candidate availability is not automatic recognition accuracy. Real video, physical display hot-plug and other hardware need further testing. This arm64 preview is ad-hoc signed and **not notarized**. Download the app ZIP and source ZIP; verify `SHA256SUMS`. Move the app to Applications and use the macOS Privacy & Security “Open Anyway” flow if needed. The optional model pack is about 89 MB installed and is not included in the ZIP.

## 繁體中文

- 保留 OCR 原文嘅網址空白、標點及 token；排版建議必須先校對。
- 新增精準框選、重讀上次原圖、可編輯候選及差異提示。取消或舊任務不會更改剪貼簿；累積重讀只替換該段一次。
- 可選原生 ONNX／PaddleOCR 第二引擎，下載會校驗；限制選區、設定逾時，完成即退出程序。模型包支援 Apple Silicon。
- 新增手動三畫面影片重讀，檢查螢幕配置，不合併不同字幕。
- 修正自動語言補讀遇到過薄區域時，連已辨識結果都失敗嘅問題。
- 英／繁中／簡中介面；提供獨立樣本分組及可重現評測。

自動替換保持停用；合成圖中出現正確候選不代表程式會自動選中。真實影片、實體多螢幕插拔及其他硬件仍待驗證。此 arm64 預覽版使用臨時簽署，**未經 Apple 公證**。請下載 App 及源碼 ZIP，核對 `SHA256SUMS`；移至「應用程式」，有需要時使用 macOS「私隱與保安 → 仍要開啟」。可選模型包磁碟約 89 MB，並未放入 ZIP。

## 简体中文

- 保留 OCR 原文的网址空白、标点和 token；排版建议须先校对。
- 新增精准框选、重读上次原图、可编辑候选及差异提示。取消或旧任务不会改动剪贴板；累积重读只替换该段一次。
- 可选原生 ONNX／PaddleOCR 第二引擎，校验下载、限制选区、设置超时，完成即退出进程。模型包支持 Apple Silicon。
- 新增手动三画面视频重读，检查屏幕配置，不合并不同字幕。
- 修复自动语言补读遇到过薄区域时丢失已有识别结果的问题。
- 英／繁中／简中界面；提供独立样本分组及可复现评测。

自动替换保持停用；合成图中有正确候选不等于程序会自动选中。真实视频、实体多屏插拔和其他硬件仍待验证。此 arm64 预览版使用临时签名，**未经 Apple 公证**。下载 App 和源码 ZIP 并核对 `SHA256SUMS`；移至“应用程序”，如被系统阻止请使用“隐私与安全性 → 仍要打开”。可选模型包磁盘约 89 MB，未包含在 ZIP 中。

---

# CaptureText v0.9.0-preview.1

## English — First public preview

Take useful text from your screen.

- Recognize a selected screen region or imported image with on-device OCR.
- Read text aloud, scan QR codes and review tables before CSV/XLSX export.
- Use macOS Continuity Camera for photos and scans when a compatible device is available.

**Install a preview:** Download the macOS ZIP from [Releases](https://github.com/yoko1234p/CaptureText/releases/tag/v0.9.0-preview.1), unzip, and move `CaptureText.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

**Requirements and limits:** Screen capture needs Screen Recording permission; file OCR does not. Continuity Camera depends on nearby compatible devices, account and network conditions. Review OCR and table structure before relying on exported data.

Before installing, check the asset SHA-256 values in `SHA256SUMS`. The source ZIP and GitHub's generated source archives are provided with this release.

## 繁體中文 — 首個公開預覽版

從畫面擷取可用文字。

- 用本機 OCR 識別框選畫面或匯入圖片。
- 朗讀文字、掃描 QR 碼，並在匯出 CSV/XLSX 前校對表格。
- 有兼容裝置時可使用 macOS 接續互通相機拍照或掃描。

**安裝預覽版:** 從 [Releases](https://github.com/yoko1234p/CaptureText/releases/tag/v0.9.0-preview.1) 下載 macOS ZIP，解壓後將 `CaptureText.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

**系統要求與限制:** 擷取畫面需要螢幕錄製權限；圖片檔 OCR 不需要。接續互通相機視乎附近裝置、帳戶及網絡條件。使用表格匯出資料前請校對。

安裝前請對照 `SHA256SUMS` 的 SHA-256 值。本版同時提供原始碼 ZIP 和 GitHub 自動產生的原始碼封存檔。

## 简体中文 — 首个公开预览版

从屏幕提取可用文字。

- 用本机 OCR 识别框选屏幕或导入图片。
- 朗读文字、扫描二维码，并在导出 CSV/XLSX 前校对表格。
- 有兼容设备时可使用 macOS 连续互通相机拍照或扫描。

**安装预览版:** 从 [Releases](https://github.com/yoko1234p/CaptureText/releases/tag/v0.9.0-preview.1) 下载 macOS ZIP，解压后将 `CaptureText.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

**系统要求与限制:** 截取屏幕需要屏幕录制权限；图片文件 OCR 不需要。连续互通相机取决于附近设备、账户及网络条件。使用表格导出数据前请校对。

安装前请核对 `SHA256SUMS` 的 SHA-256 值。本版同时提供源代码 ZIP 和 GitHub 自动生成的源代码压缩包。
