import DeskCore
import Foundation

public enum CaptureOutput {
    /// Additive capture uses its own session buffer, never the editable review text or another app's clipboard.
    public static func combine(_ output: String, buffer: inout String, additive: Bool) -> String {
        guard additive else { return output }
        buffer = buffer.isEmpty ? output : buffer + "\n" + output
        return buffer
    }

    /// Reject overflow before changing the buffer. The newline occupies one UTF-8 byte.
    public static func combine(_ output: String, buffer: inout String, additive: Bool, byteLimit: Int) throws -> String
    {
        guard additive else { return output }
        let separatorBytes = buffer.isEmpty ? 0 : 1
        guard byteLimit >= 0, buffer.utf8.count <= byteLimit,
            output.utf8.count <= byteLimit - buffer.utf8.count - separatorBytes
        else { throw CaptureOutputError.bufferFull }
        return combine(output, buffer: &buffer, additive: true)
    }
}

public enum CaptureOutputError: LocalizedError {
    case bufferFull
    public var errorDescription: String? {
        L10n.text("累積文字已達 1 MB；請清除累積文字再擷取。剪貼簿保持原狀。")
    }
}
