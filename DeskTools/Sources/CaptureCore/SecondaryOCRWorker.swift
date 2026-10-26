import CoreGraphics
import Darwin
import DeskCore
import Foundation
import ImageIO

public enum SecondaryOCRWorker {
    /// A fresh helper process owns the model and releases all of its pages on exit.
    /// Private image files exist only for the duration of this explicit operation.
    public static func recognize(
        _ image: CGImage, document: OCRDocument, language: OCRLanguage,
        executable: URL, cancellation: RecognitionCancellation, timeout: Duration = .seconds(25)
    ) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.png")
        let request = folder.appendingPathComponent("request.json")
        let output = folder.appendingPathComponent("result.json")
        try cancellation.check()
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(OCRWorkerRequest(document: document, language: language)).write(
            to: request, options: .atomic)
        let process = Process()
        process.executableURL = executable
        process.arguments = [input.path, request.path, output.path, OCRModelPack.directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try cancellation.check()
        try Task.checkCancellation()
        try process.run()
        // Foundation observes and reaps the child. Do not call waitUntilExit after
        // an await: the task may resume on a different thread/run loop and hang.
        // On cancellation SIGKILL closes the helper's file handles; unlinking its
        // private directory is safe even while the kernel finishes termination.
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            try cancellation.check()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw DeskError.invalid(L10n.text("第二引擎逾時，原始結果已保留。")) }
            try await Task.sleep(for: .milliseconds(40))
        }
        try cancellation.check()
        try Task.checkCancellation()
        guard (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 1_000_000 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let result = try JSONDecoder().decode(OCRWorkerResponse.self, from: Data(contentsOf: output))
        guard process.terminationStatus == 0, let text = result.text else {
            throw DeskError.invalid(result.error ?? L10n.text("第二引擎辨識未完成，原始結果已保留。"))
        }
        return text
    }
}
