import AVFoundation
import CaptureCore
import Combine
import DeskCore
import Foundation
import NaturalLanguage

struct CaptureSpeechVoice: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: Int
    let isNovelty: Bool
    var id: String { identifier }
    var title: String {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
        return "\(name) · \(languageName)"
    }

    init(identifier: String, name: String, language: String, quality: Int = 1, isNovelty: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
    }

    static func installed() -> [CaptureSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard AVSpeechSynthesisVoice(identifier: voice.identifier) != nil else { return nil }
            return CaptureSpeechVoice(
                identifier: voice.identifier, name: voice.name, language: voice.language,
                quality: voice.quality.rawValue, isNovelty: voice.voiceTraits.contains(.isNoveltyVoice))
        }.sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
    }
}

struct CaptureSpeechSegment: Equatable, Sendable {
    let text: String
    let voiceID: String
    let language: String
}

enum CaptureSpeechError: LocalizedError, Equatable {
    case emptyText, tooMuchText, tooManySegments, undeterminedLanguage
    case unavailableVoice(String)

    var errorDescription: String? {
        switch self {
        case .emptyText: return L10n.text("沒有可朗讀文字。")
        case .tooMuchText: return L10n.text("朗讀文字最多 100,000 字元，請選取較短的內容。")
        case .tooManySegments: return L10n.text("朗讀最多 128 段，請分批選取內容。")
        case .undeterminedLanguage: return L10n.text("無法判斷朗讀語言，請在設定選擇聲音。")
        case .unavailableVoice(let language):
            return L10n.text(
                "沒有可用的朗讀聲音（%1$@）。請在 macOS 輔助使用的朗讀設定下載聲音，或在 CaptureText 選擇聲音。", String(describing: language))
        }
    }
}

enum CaptureSpeechPlanner {
    static func detectLanguage(_ text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    /// Voice discovery is supplied by the caller; planning never requests downloads or plays audio.
    static func plan(
        text: String, language: OCRLanguage, selectedVoiceID: String = "", voices: [CaptureSpeechVoice],
        detectLanguage: (String) -> String? = CaptureSpeechPlanner.detectLanguage
    ) throws -> [CaptureSpeechSegment] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CaptureSpeechError.emptyText }
        guard text.count <= 100_000 else { throw CaptureSpeechError.tooMuchText }
        let fragments = try segments(text)
        if !selectedVoiceID.isEmpty {
            guard let voice = voices.first(where: { $0.identifier == selectedVoiceID }) else {
                throw CaptureSpeechError.unavailableVoice(L10n.text("已選聲音"))
            }
            return fragments.map { CaptureSpeechSegment(text: $0, voiceID: voice.identifier, language: voice.language) }
        }
        var previousLanguage: String?
        return try fragments.map { fragment in
            let code = language == .automatic ? detectLanguage(fragment) ?? previousLanguage : language.codes.first
            guard let code else { throw CaptureSpeechError.undeterminedLanguage }
            guard let voice = matchingVoice(for: code, voices: voices) else {
                throw CaptureSpeechError.unavailableVoice(code)
            }
            previousLanguage = code
            return CaptureSpeechSegment(text: fragment, voiceID: voice.identifier, language: voice.language)
        }
    }

    static func matchingVoice(for code: String, voices: [CaptureSpeechVoice]) -> CaptureSpeechVoice? {
        let normalized = normalize(code)
        let preferred: [String]
        switch normalized {
        case "zh-hant", "zh-hk", "zh": preferred = ["yue-hk", "zh-tw"]
        case "zh-hans": preferred = ["zh-cn"]
        case "yue", "yue-hant", "yue-hans": preferred = ["yue-hk"]
        case "vi-vt": preferred = ["vi-vn"]  // Vision's Vietnamese locale spelling.
        case "no", "no-no": preferred = ["nb-no"]
        default: preferred = [normalized]
        }
        for language in preferred {
            if let exact = best(voices.filter { normalize($0.language) == language }) { return exact }
        }
        // Regional accents may fall back within the same language; never switch an unsupported language to English.
        let base = preferred.last?.split(separator: "-").first.map(String.init) ?? normalized
        return best(voices.filter { normalize($0.language).split(separator: "-").first.map(String.init) == base })
    }

    private static func normalize(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func best(_ voices: [CaptureSpeechVoice]) -> CaptureSpeechVoice? {
        voices.sorted {
            if $0.isNovelty != $1.isNovelty { return !$0.isNovelty }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return ($0.name, $0.identifier) < ($1.name, $1.identifier)
        }.first
    }

    private static func segments(_ text: String) throws -> [String] {
        var fragments: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = line
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                sentences.append(String(line[range]))
                return sentences.count <= 128
            }
            guard sentences.count <= 128 else { throw CaptureSpeechError.tooManySegments }
            for sentence in sentences.isEmpty ? [line] : sentences {
                var remaining = sentence[...]
                while !remaining.isEmpty {
                    let end =
                        remaining.index(remaining.startIndex, offsetBy: 4000, limitedBy: remaining.endIndex)
                        ?? remaining.endIndex
                    let boundary =
                        end == remaining.endIndex ? end : remaining[..<end].lastIndex(where: \.isWhitespace) ?? end
                    let cut = boundary > remaining.startIndex ? boundary : end
                    let fragment = remaining[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fragment.isEmpty { fragments.append(fragment) }
                    guard fragments.count <= 128 else { throw CaptureSpeechError.tooManySegments }
                    remaining = remaining[cut...].drop(while: \.isWhitespace)
                }
            }
        }
        return fragments
    }
}

@MainActor protocol CaptureSpeechPlayback: AnyObject {
    var onCompletion: (() -> Void)? { get set }
    func speak(_ segments: [CaptureSpeechSegment], rate: Float) throws
    func stop()
}

@MainActor final class CaptureSpeechController: ObservableObject {
    static let rateRange = 0.1...0.7
    @Published var selectedVoiceID: String { didSet { defaults.set(selectedVoiceID, forKey: "captureSpeechVoiceID") } }
    @Published var rate: Double {
        didSet {
            let normalized = Self.validRate(rate)
            if rate != normalized { rate = normalized }
            defaults.set(normalized, forKey: "captureSpeechRate")
        }
    }
    @Published private(set) var availableVoices: [CaptureSpeechVoice]
    @Published private(set) var isSpeaking = false
    @Published private(set) var status = ""
    private let defaults: UserDefaults
    private let playback: CaptureSpeechPlayback
    private let detectLanguage: (String) -> String?
    private let injectedVoices: Bool
    private var voiceObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard, voices: [CaptureSpeechVoice]? = nil,
        detectLanguage: @escaping (String) -> String? = CaptureSpeechPlanner.detectLanguage,
        playback: CaptureSpeechPlayback? = nil
    ) {
        self.defaults = defaults
        self.detectLanguage = detectLanguage
        self.playback = playback ?? CaptureSystemSpeechPlayback()
        injectedVoices = voices != nil
        availableVoices = voices ?? CaptureSpeechVoice.installed()
        selectedVoiceID = defaults.string(forKey: "captureSpeechVoiceID") ?? ""
        rate = Self.validRate(
            defaults.object(forKey: "captureSpeechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
        self.playback.onCompletion = { [weak self] in
            guard let self, self.isSpeaking else { return }
            self.isSpeaking = false
            self.status = L10n.text("朗讀完成。")
        }
        if !injectedVoices {
            voiceObserver = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshVoices() }
            }
        }
    }

    deinit { if let voiceObserver { NotificationCenter.default.removeObserver(voiceObserver) } }

    func refreshVoices() { if !injectedVoices { availableVoices = CaptureSpeechVoice.installed() } }
    func stop() {
        isSpeaking = false
        playback.stop()
        status = L10n.text("已停止朗讀。")
    }
    func toggle(text: String, language: OCRLanguage) {
        if isSpeaking { stop() } else { speak(text: text, language: language) }
    }
    func speak(text: String, language: OCRLanguage) {
        stop()
        do {
            let segments = try CaptureSpeechPlanner.plan(
                text: text, language: language, selectedVoiceID: selectedVoiceID, voices: availableVoices,
                detectLanguage: detectLanguage)
            try playback.speak(segments, rate: Float(rate))
            isSpeaking = true
            status = L10n.text("朗讀中 · %1$@ 段", String(describing: segments.count))
        } catch {
            status = error.localizedDescription
        }
    }
    private static func validRate(_ value: Double) -> Double {
        value.isFinite
            ? min(rateRange.upperBound, max(rateRange.lowerBound, value)) : Double(AVSpeechUtteranceDefaultSpeechRate)
    }
}

@MainActor private final class CaptureSystemSpeechPlayback: NSObject, CaptureSpeechPlayback, AVSpeechSynthesizerDelegate
{
    var onCompletion: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = Set<ObjectIdentifier>()

    override init() {
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ segments: [CaptureSpeechSegment], rate: Float) throws {
        let utterances = try segments.map { segment -> AVSpeechUtterance in
            guard let voice = AVSpeechSynthesisVoice(identifier: segment.voiceID) else {
                throw CaptureSpeechError.unavailableVoice(segment.language)
            }
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = rate
            return utterance
        }
        pending = Set(utterances.map(ObjectIdentifier.init))
        for utterance in utterances { synthesizer.speak(utterance) }
    }
    func stop() {
        pending.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }
    private func completed(_ id: ObjectIdentifier) {
        guard pending.remove(id) != nil, pending.isEmpty else { return }
        onCompletion?()
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.completed(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.completed(id) }
    }
}
