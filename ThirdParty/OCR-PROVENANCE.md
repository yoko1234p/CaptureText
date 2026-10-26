# Optional OCR components

- ONNX Runtime 1.31.0: https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0 (MIT). Vendored C headers and license/notices; the runtime is downloaded separately.
- PaddleOCR: https://github.com/PaddlePaddle/PaddleOCR/tree/v3.7.0 (Apache-2.0). Bundled character dictionaries, optional official ONNX models.
- Multilingual: https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/tree/b8f84f0b80c529de40b4fbb3544b84fa7233a513
- English: https://huggingface.co/PaddlePaddle/en_PP-OCRv5_mobile_rec_onnx/tree/3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b
- Korean: https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/tree/5c6f574b8e2230adf4287b33e736d71b9fabd28e

The exact download sizes, revisions and SHA-256 values are maintained in `OCRModelPack.swift`. Dictionary entries follow each model's `inference.yml`, with CTC blank prepended and a space appended. No pretrained model weights or runtime dylib are included in the application ZIP or source repository.

All component licenses remain separate from the application's GPL-3.0-only license.
