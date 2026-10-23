import Foundation
import Vision

public enum RecognitionKind: Equatable, Sendable {
    case text, barcodes, table
}

/// Options are captured when the user begins a capture, before selection or OCR.
public struct CaptureRecognitionOptions: Sendable {
    public let kind: RecognitionKind
    public let language: OCRLanguage
    public let words: [String]
    public let singleLine: Bool

    public init(kind: RecognitionKind, language: OCRLanguage, words: [String], singleLine: Bool) {
        self.kind = kind
        self.language = language
        self.words = Array(words.prefix(500))
        self.singleLine = singleLine
    }
}

/// A task can be cancelled before Vision starts, while it is running, or before delivery.
public final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let active = request
        lock.unlock()
        active?.cancel()
    }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func begin(_ request: VNRequest) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.request = request
        lock.unlock()
    }

    func finish() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}
