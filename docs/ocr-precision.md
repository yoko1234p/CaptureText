# Precision OCR

CaptureText 0.10 preserves the OCR output before formatting. In particular, URL spaces, punctuation, capitalization and tokens are not silently repaired. An explicit URL whitespace suggestion is available in review; it is formatting, not evidence of accuracy.

## Using it

- **Capture for Precision Review** selects a new region and opens a small review panel. No clipboard or speech side effect happens until **Accept and Copy**.
- **Reread Last Image** is available for two minutes after a single text capture. It uses the original pixel crop, not the thumbnail. In additive mode, accepting replaces that capture's segment instead of appending a duplicate.
- Compare the original image and output with the literal, enlarged and optional second-engine candidates. Edit before accepting. Yellow marks a changed span, not a calibrated confidence score. Escape cancels.
- **Reread Video Frames** takes the selected frame and two more samples, 180 ms apart, on the selected display. Only a sharper, visually stable sample with exactly matching recognized text can contribute candidates. Changed subtitles and display configurations fall back to the original. It does not record a video or combine text across subtitles.
- Assign shortcuts in Settings → Shortcuts. New actions have no default shortcut and do not overwrite existing bindings.

## Privacy and resource limits

Normal capture still uses Apple Vision. Precision work is serial: original, literal (language correction off), and at most one 2× enlargement for small text. Owned crops are limited to 16 megapixels, avoiding retention of the entire display buffer. The last crop expires after two minutes; an open review retains its image until closed or replaced. Large or multipage imports remain available through normal recognition.

The optional Apple Silicon model pack downloads about 79 MB and occupies about 89 MB (85 MiB) on disk. It includes ONNX Runtime 1.31.0 and pinned PaddleOCR multilingual, English and Korean models. Downloads have fixed revision URLs, byte counts and SHA-256 verification. Models load in a fresh native helper process only during precision review, at two inference threads, with a 25-second deadline and at most 12 text regions. The helper exits afterward, releasing its runtime and model pages. There is no bundled Python environment.

The helper exchanges the selected crop through a private temporary directory (mode 0700). The directory is removed after success, error, timeout or cancellation. A forced OS/app termination can prevent cleanup; these files are temporary, not an OCR history. No image or recognized text is sent to the download servers. The download itself contacts GitHub and Hugging Face. Runtime and models remain in `~/Library/Application Support/CaptureText/OCRModels/`; removing that folder while the app is closed uninstalls the optional pack.

Models are alternate recognizers, not guaranteed improvements. The multilingual model does not provide Korean coverage; the dedicated Korean model is selected for Korean mode or recognized Hangul. Explicit English uses the English model. Automatic mixed Korean/non-Korean crops may need smaller selections and manual language choice. Unsupported/oversized inputs and engine failures preserve the Vision output.

## Validation and automatic replacement

Automatic replacement remains disabled. Optional automatic review only opens the review panel after a short crop or URL; normal auto-copy may already have copied the original. Accepting is always explicit. Agreement between engines or a Vision confidence of 1.0 is not treated as proof.

The evaluation runner uses the actual `Recognition.document` pipeline, including automatic-language region recovery. Timing excludes scoring. Whole-URL exact match, character edits and punctuation exact match are separate. Candidate availability is an oracle upper bound: it says a correct candidate existed, not that the program knew which one was correct.

Generate synthetic fixtures and run the release benchmark:

```sh
swift DeskTools/Scripts/ocr-fixtures.swift artifacts/ocr-validation/fixtures
swift build --package-path DeskTools -c release
DeskTools/.build/release/CaptureOCRBench artifacts/ocr-validation/fixtures/manifest.json artifacts/ocr-validation/results.json
# Optional native engine, after explicit installation:
DeskTools/.build/release/CaptureOCRBench --install-models
DeskTools/.build/release/CaptureOCRBench artifacts/ocr-validation/fixtures/manifest.json artifacts/ocr-validation/results.json --secondary
```

Use `swift build --package-path DeskTools -c release --show-bin-path` if the build system uses a different output directory. The first Vision sample is cold; subsequent samples are warm. Every secondary-engine sample includes fresh helper startup, hash checks, model load, inference and process exit. Precision timing is additional to the baseline pass, not end-to-end screenshot latency.

The manifest contains `id`, `sourceGroup`, `split` (`calibration` or `holdout`), `image`, `expected`, `language` (the OCRLanguage raw value) and `realScreen`. All font/compression variants of a source must remain in one split. The runner rejects overlapping source groups. Synthetic validation alone never enables automatic replacement. A future replacement policy must be fixed using calibration data, then evaluated on at least 30 independent real screen sources with at least 3 corrected sources, zero regressed sources and fewer total character edits. This is a minimum release gate, not a statistical accuracy guarantee.

Missing coverage: physical multi-monitor hot-plug during a video capture, actual changing video subtitles, other Mac hardware and Intel execution need further user/device testing. Native macOS permissions and Continuity Camera are unchanged.

## Measured on this Mac, 26 October 2026

[Machine-readable summary](ocr-validation-2026-10-26.json). This is a synthetic evaluation, not a real-world accuracy claim. Forty independent text sources produced 160 font/background/compression variants. Thirty sources (120 images) were held out; no automatic selector was trained or enabled.

| Held-out set | Original exact | Correct Vision candidate available | Correct candidate available including second engine |
| --- | ---: | ---: | ---: |
| All 120 images | 74 / 120 | 81 / 120 | 95 / 120 |
| 48 URL images | 23 / 48 | 26 / 48 | 29 / 48 |

These candidate figures require a person to identify and choose the correct result. Substituting the second engine indiscriminately would regress 23 originally correct held-out images, including 6 URLs. Two held-out second-engine requests returned no result; the app retains the original. System OCR's held-out character error rate was 1.69%; punctuation matched exactly on 107/120 images.

Release-build median timings after the first request: system OCR 36 ms, additional Vision rereading 71 ms, native helper 132 ms. P95: 72 / 118 / 137 ms respectively. These exclude screenshot acquisition and user review; the helper includes startup, checksum checks, model load and exit, with OS file caches warm. The 160-image run completed in 39 seconds. A separate packaged English-worker smoke run reached 112 MiB maximum RSS and exited; this is one sample, not a memory ceiling. App bundle size grew from approximately 3.5 to 5.6 MiB; optional models are separate. No memory reduction against the previous app version is claimed.

Validation: 84 CaptureText-only tests, three-language packaged catalog checks, verified model extraction, packaged native worker inference, and native review-panel editing/accept/cancel checks. See the release notes for hardware and video coverage still outstanding.
