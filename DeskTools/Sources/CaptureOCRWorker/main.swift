import CaptureCore
import Foundation
import ImageIO

// The parent owns this private temporary directory and deletes it on every exit.
// Exiting the worker releases the ONNX session, allocator and model pages.
let args = CommandLine.arguments
guard args.count == 5 else { exit(2) }
let input = URL(fileURLWithPath: args[1])
let requestURL = URL(fileURLWithPath: args[2])
let output = URL(fileURLWithPath: args[3])
let pack = URL(fileURLWithPath: args[4])
do {
    let inputSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    let requestSize = try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard inputSize <= 80_000_000, requestSize <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
    let request = try JSONDecoder().decode(OCRWorkerRequest.self, from: Data(contentsOf: requestURL))
    guard request.document.width > 0, request.document.height > 0,
        request.document.width <= OCRImageBuffer.maximumPixels / request.document.height,
        let source = CGImageSourceCreateWithURL(input as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width == request.document.width, height == request.document.height,
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    let text = try PaddleOCR.recognize(
        image, document: request.document, language: request.language,
        directory: pack, cancellation: RecognitionCancellation())
    try JSONEncoder().encode(OCRWorkerResponse(text: text)).write(to: output, options: .atomic)
} catch {
    try? JSONEncoder().encode(OCRWorkerResponse(error: error.localizedDescription)).write(to: output, options: .atomic)
    exit(1)
}
