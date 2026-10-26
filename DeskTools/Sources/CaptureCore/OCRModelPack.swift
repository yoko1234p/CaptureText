import CryptoKit
import DeskCore
import Foundation

public enum OCRModel: String, CaseIterable, Codable, Sendable {
    case multilingual, english, korean
    public var filename: String { rawValue + ".onnx" }
    public var dictionary: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }
    }
    public var repository: String {
        switch self {
        case .multilingual: return "PP-OCRv6_small_rec_onnx"
        case .english: return "en_PP-OCRv5_mobile_rec_onnx"
        case .korean: return "korean_PP-OCRv5_mobile_rec_onnx"
        }
    }
    public var revision: String {
        switch self {
        case .multilingual: return "b8f84f0b80c529de40b4fbb3544b84fa7233a513"
        case .english: return "3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b"
        case .korean: return "5c6f574b8e2230adf4287b33e736d71b9fabd28e"
        }
    }
    public var sha256: String {
        switch self {
        case .multilingual: return "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"
        case .english: return "b5f833dfc5d0eb71da397b4efa06ebeee9b431b690a47d6af40d77d8eabc557f"
        case .korean: return "92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08"
        }
    }
    public var bytes: Int64 {
        switch self {
        case .multilingual: return 21_159_378
        case .english: return 7_848_423
        case .korean: return 13_418_787
        }
    }
    public var url: URL {
        URL(string: "https://huggingface.co/PaddlePaddle/\(repository)/resolve/\(revision)/inference.onnx")!
    }
    public static func choose(language: OCRLanguage, text: String) -> OCRModel {
        if language == .korean { return .korean }
        if language == .english { return .english }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return .korean }
        return .multilingual
    }
}

public actor OCRModelPack {
    public static let shared = OCRModelPack()
    public static let runtimeName = "libonnxruntime.1.31.0.dylib"
    public static let runtimeLibraryHash = "2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70"
    public static let runtimeArchiveHash = "1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc"
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureText/OCRModels/v1.31.0-20261026", isDirectory: true)
    }
    public static var installed: Bool {
        let paths = [runtimeName] + OCRModel.allCases.map(\.filename) + ["verified.json"]
        return paths.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
    private var installing = false

    public func install(progress: @escaping @Sendable (String) async -> Void) async throws {
        #if !arch(arm64)
            throw DeskError.invalid(L10n.text("第二引擎模型包目前支援 Apple Silicon。"))
        #else
            guard !installing else { throw DeskError.invalid(L10n.text("模型包正在下載。")) }
            if Self.installed { return }
            installing = true
            defer { installing = false }
            let parent = Self.directory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stage = parent.appendingPathComponent(".install-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stage) }
            await progress(L10n.text("下載本機 OCR 引擎…"))
            let archive = stage.appendingPathComponent("runtime.tgz")
            try await Self.download(
                URL(
                    string:
                        "https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-osx-arm64-1.31.0.tgz"
                )!,
                to: archive, bytes: 36_549_009, hash: Self.runtimeArchiveHash)
            try Task.checkCancellation()
            try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = [
                    "-xzf", archive.path, "-C", stage.path, "--strip-components=3",
                    "./onnxruntime-osx-arm64-1.31.0/lib/" + Self.runtimeName,
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw DeskError.invalid(L10n.text("無法解開 OCR 引擎。")) }
            }.value
            guard try Self.fileHash(stage.appendingPathComponent(Self.runtimeName)) == Self.runtimeLibraryHash else {
                throw DeskError.invalid(L10n.text("OCR 模型校驗失敗。"))
            }
            try FileManager.default.removeItem(at: archive)
            for model in OCRModel.allCases {
                try Task.checkCancellation()
                await progress(L10n.text("下載 OCR 模型：%1$@", model.rawValue))
                try await Self.download(
                    model.url, to: stage.appendingPathComponent(model.filename), bytes: model.bytes, hash: model.sha256)
            }
            try Task.checkCancellation()
            let marker = try JSONEncoder().encode(OCRModel.allCases.map(\.sha256))
            try marker.write(to: stage.appendingPathComponent("verified.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: Self.directory.path) {
                try FileManager.default.removeItem(at: Self.directory)
            }
            try FileManager.default.moveItem(at: stage, to: Self.directory)
        #endif
    }

    private static func download(_ url: URL, to destination: URL, bytes: Int64, hash: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(bytes)
        else {
            throw DeskError.invalid(L10n.text("OCR 模型下載不完整。"))
        }
        let actual = try await Task.detached { try fileHash(temporary) }.value
        guard actual == hash else { throw DeskError.invalid(L10n.text("OCR 模型校驗失敗。")) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
