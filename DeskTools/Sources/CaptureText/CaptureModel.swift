import AppKit
import CaptureCore
import Combine
import DeskCore
import DeskUI
import LocalWorkflowKit
import ScreenCaptureKit
import SwiftUI

@MainActor final class CaptureModel: ObservableObject {
    @Published var text = ""
    @Published var message = L10n.text("框選螢幕文字，或開啟圖片開始。")
    @Published var busy = false
    @Published var failed = false
    @Published var preview: NSImage?
    @Published var collectionSource = DraftSource(application: "CaptureText OCR")
    @Published var tables: [RecognizedTable] = []
    @Published var tableIndex = 0
    @Published var protectTableFormulas = true
    @Published var settingsPage = "general"
    @Published var language: OCRLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var singleLine: Bool { didSet { defaults.set(singleLine, forKey: "singleLine") } }
    @Published var append: Bool { didSet { defaults.set(append, forKey: "append") } }
    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    @Published var customWords: String {
        didSet { defaults.set(String(customWords.prefix(20_000)), forKey: "customWords") }
    }
    @Published var speechAfterCapture: Bool {
        didSet { defaults.set(speechAfterCapture, forKey: "speechAfterCapture") }
    }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "sound") } }
    @Published var feedback: Bool { didSet { defaults.set(feedback, forKey: "feedback") } }
    @Published var hasLastSelection = false
    @Published var canReread = false
    @Published var review: OCRPrecisionResult?
    @Published var reviewDraft = ""
    @Published var reviewImage: NSImage?
    @Published var reviewStatus = ""
    @Published var reviewVisible = false
    @Published var secondaryEnabled: Bool { didSet { defaults.set(secondaryEnabled, forKey: "secondaryOCR") } }
    @Published var offerPrecision: Bool { didSet { defaults.set(offerPrecision, forKey: "offerPrecision") } }
    @Published var modelsInstalled = OCRModelPack.installed
    @Published var modelDownloadStatus = ""
    @Published var downloadingModels = false
    private var downloadTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private struct RetainedCapture {
        let image: CGImage
        let options: WorkflowOptions
        let prefix: String
        let committedText: String?
    }
    private var retainedCapture: RetainedCapture?
    private var reviewContext: RetainedCapture?
    var showReviewPanel: () -> Void = {}
    var hideReviewPanel: () -> Void = {}
    var precisionOperation:
        @Sendable (CGImage, CaptureRecognitionOptions, RecognitionCancellation) async throws -> OCRPrecisionResult = {
            image, options, cancellation in
            try await Task.detached(priority: .userInitiated) {
                try OCRPrecision.recognize(image, options: options, cancellation: cancellation)
            }.value
        }
    let screenAccess: CaptureScreenAccess
    let speech: CaptureSpeechController
    let loginItem = CaptureLoginItem()
    let supportedOCRCodes = (try? Recognition.supportedLanguageCodes()) ?? []
    var availableOCRLanguages: [OCRLanguage] {
        OCRLanguage.allCases.filter { $0.isSupported(by: supportedOCRCodes) || $0 == language }
    }
    var loadShareableContent: () async throws -> SCShareableContent = {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    private var previousApp: NSRunningApplication?
    private var nextCollectionSource = DraftSource(application: "CaptureText OCR")
    private var captureScreen: NSScreen?
    private let defaults: UserDefaults
    private struct WorkflowOptions {
        let source: DraftSource
        let recognition: CaptureRecognitionOptions
        let quiet: Bool
        let returnOnCancel: Bool
        let autoCopy: Bool
        let append: Bool
        let speech: Bool
        let sound: Bool
        let feedback: Bool
    }
    private var activeOptions: WorkflowOptions?
    private var operationTask: Task<Void, Never>?
    private var recognitionCancellation: RecognitionCancellation?
    private var additiveText = ""
    private var lastSelection: (display: UInt32, frame: CGRect, pixels: CGSize, crop: CGRect)?
    private let toast = TransientFeedback()
    var copyText: (String) -> Void = { AppSupport.copy($0) }
    var showWindow: () -> Void = {}
    var hideWindow: () -> Void = {}
    var restoreForegroundApplication: (NSRunningApplication?) -> Void = { app in
        if let app, !app.isTerminated { app.activate(options: []) }
    }
    var recognitionOperation:
        @Sendable (CGImage, CaptureRecognitionOptions, RecognitionCancellation) async throws -> String = {
            image, options, cancellation in
            if options.kind == .table {
                let tables = try await TableRecognition.recognize(
                    image, language: options.language, words: options.words, cancellation: cancellation)
                return String(decoding: try JSONEncoder().encode(tables), as: UTF8.self)
            }
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    switch options.kind {
                    case .text:
                        return try Recognition.text(
                            image, language: options.language, words: options.words, singleLine: options.singleLine,
                            cancellation: cancellation)
                    case .barcodes:
                        return try Recognition.barcodes(image, cancellation: cancellation)
                    case .table: throw DeskError.invalid(L10n.text("表格辨認未完成。"))
                    }
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        }
    private var panels: [NSPanel] = []
    private var token = UUID()
    private var escapeMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, screenAccess: CaptureScreenAccess? = nil) {
        self.defaults = defaults
        self.screenAccess = screenAccess ?? CaptureScreenAccess()
        self.speech = CaptureSpeechController(defaults: defaults)
        language = OCRLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .automatic
        singleLine = defaults.bool(forKey: "singleLine")
        append = defaults.bool(forKey: "append")
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        customWords = defaults.string(forKey: "customWords") ?? ""
        speechAfterCapture = defaults.bool(forKey: "speechAfterCapture")
        sound = defaults.object(forKey: "sound") as? Bool ?? true
        feedback = defaults.object(forKey: "feedback") as? Bool ?? true
        secondaryEnabled = defaults.bool(forKey: "secondaryOCR")
        offerPrecision = defaults.bool(forKey: "offerPrecision")
    }

    private func options(barcode: Bool, quiet: Bool, returnOnCancel: Bool, singleLine: Bool?, table: Bool = false)
        -> WorkflowOptions
    {
        WorkflowOptions(
            source: nextCollectionSource,
            recognition: CaptureRecognitionOptions(
                kind: table ? .table : barcode ? .barcodes : .text, language: language,
                words: customWords.prefix(20_000).split(separator: "\n").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }, singleLine: table ? false : singleLine ?? self.singleLine),
            quiet: quiet && !table, returnOnCancel: returnOnCancel, autoCopy: autoCopy && !table,
            append: append && !table,
            speech: speechAfterCapture, sound: sound, feedback: feedback)
    }

    func capture(
        barcode: Bool = false, last: Bool = false, singleLine: Bool? = nil, table: Bool = false, precise: Bool = false,
        video: Bool = false
    ) {
        toast.hide()
        rememberForegroundApplication()
        cancel(show: false)
        let options = options(
            barcode: barcode, quiet: autoCopy, returnOnCancel: true, singleLine: singleLine, table: table)
        captureScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        if last && lastSelection == nil {
            toast.show(L10n.text("未有上次選區，請先框選一次。"), error: true, on: captureScreen)
            return
        }
        failed = false
        busy = true
        activeOptions = options
        message = L10n.text("準備擷取畫面…")
        let current = token
        hideWindow()
        operationTask = Task { [self] in
            do {
                // Menu commands reach here after menu tracking. Allow our own windows to
                // disappear, then exclude this app as well. No screenshot is written to disk.
                try await Task.sleep(for: .milliseconds(180))
                guard current == token, !Task.isCancelled else { return }
                let content = try await loadShareableContent()
                screenAccess.didObtainContent()
                var snapshots: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard current == token, !Task.isCancelled else { return }
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                        let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                    else { continue }
                    let ownApps = content.applications.filter {
                        $0.processID == ProcessInfo.processInfo.processIdentifier
                    }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard current == token else { return }
                    snapshots.append((screen, image))
                }
                guard !snapshots.isEmpty else { throw DeskError.invalid(L10n.text("沒有可擷取的螢幕。")) }
                guard current == token else { return }
                if last, let saved = lastSelection {
                    guard
                        let (screen, image) = snapshots.first(where: {
                            ($0.0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                                == saved.display
                        }), screen.frame == saved.frame,
                        CGSize(width: image.width, height: image.height) == saved.pixels,
                        let crop = image.cropping(to: saved.crop)
                    else {
                        lastSelection = nil
                        hasLastSelection = false
                        throw DeskError.invalid(L10n.text("螢幕配置已改變，請重新框選。"))
                    }
                    captureScreen = screen
                    if precise || video {
                        beginReview(crop, options: options, video: video)
                    } else {
                        recognize(crop, options: options)
                    }
                    return
                }
                message = L10n.text("拖曳框選，Esc 取消。")
                NSApp.activate(ignoringOtherApps: true)
                for (screen, image) in snapshots {
                    let panel = SelectionPanel(
                        contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    panel.isReleasedWhenClosed = false
                    panel.hidesOnDeactivate = false
                    panel.acceptsMouseMovedEvents = true
                    panel.isMovable = false
                    panel.hasShadow = false
                    panel.setAccessibilityIdentifier("capture.selection-overlay")
                    panel.contentView = SelectionView(image: image, size: screen.frame.size) { [weak self] crop, rect in
                        guard let self, current == self.token else { return }
                        let selectedOptions = self.activeOptions ?? options
                        self.closePanels()
                        if let crop, let rect {
                            self.captureScreen = screen
                            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                                as? NSNumber
                            {
                                self.lastSelection = (
                                    number.uint32Value, screen.frame,
                                    CGSize(width: image.width, height: image.height), rect
                                )
                                self.hasLastSelection = true
                            }
                            if precise || video {
                                self.beginReview(crop, options: selectedOptions, video: video)
                            } else {
                                self.recognize(crop, options: selectedOptions)
                            }
                        } else {
                            self.cancel()
                        }
                    }
                    (panel.contentView as? SelectionView)?.statusText = selectionStatus(options)
                    panels.append(panel)
                    panel.orderFrontRegardless()
                    if screen.frame.contains(NSEvent.mouseLocation) {
                        panel.makeKey()
                        panel.makeFirstResponder(panel.contentView)
                    }
                }
                for panel in panels {
                    if let selection = panel.contentView as? SelectionView {
                        panel.invalidateCursorRects(for: selection)
                        selection.updateTrackingAreas()
                        selection.refreshSelectionCursor()
                    }
                }
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 {
                        self?.cancel()
                        return nil
                    }
                    if event.modifierFlags.contains(.command),
                        let command = event.charactersIgnoringModifiers?.lowercased(),
                        self?.toggleSelectionOption(command) == true
                    {
                        return nil
                    }
                    return event
                }
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in Task { @MainActor in self?.cancel() } }
            } catch {
                guard current == token else { return }
                busy = false
                activeOptions = nil
                operationTask = nil
                failed = true
                if screenAccess.handle(error) {
                    message = CaptureScreenAccess.recoveryMessage
                    showWindow()
                    return
                }
                message = error.localizedDescription
                if options.quiet {
                    restoreFocus()
                    toast.show(L10n.text("擷取失敗，請從選單查看結果。"), error: true, on: captureScreen)
                } else {
                    showWindow()
                }
            }
        }
    }

    @discardableResult func toggleSelectionOption(_ command: String) -> Bool {
        guard !panels.isEmpty, let previous = activeOptions, ["l", "h", "s"].contains(command) else { return false }
        var merged = previous.recognition.singleLine
        var additive = previous.append
        var speech = previous.speech
        switch command {
        case "l":
            merged.toggle()
            singleLine = merged
        case "h":
            additive.toggle()
            append = additive
        case "s":
            speech.toggle()
            speechAfterCapture = speech
        default: return false
        }
        let selected = WorkflowOptions(
            source: previous.source,
            recognition: CaptureRecognitionOptions(
                kind: previous.recognition.kind, language: previous.recognition.language,
                words: previous.recognition.words, singleLine: merged),
            quiet: previous.quiet, returnOnCancel: previous.returnOnCancel, autoCopy: previous.autoCopy,
            append: additive, speech: speech, sound: previous.sound, feedback: previous.feedback)
        activeOptions = selected
        for panel in panels { (panel.contentView as? SelectionView)?.statusText = selectionStatus(selected) }
        return true
    }
    private func selectionStatus(_ options: WorkflowOptions) -> String {
        let kind = options.recognition.kind == .barcodes ? L10n.text("QR／條碼") : L10n.text("擷取文字")
        return kind + (options.recognition.singleLine ? L10n.text(" · 單行") : L10n.text(" · 換行"))
            + (options.append ? L10n.text(" · 累積") : "") + (options.speech ? L10n.text(" · 朗讀") : "")
            + L10n.text(" · Esc 取消")
    }

    func recognize(
        _ image: CGImage, barcode: Bool = false, quiet: Bool = false, singleLine: Bool? = nil, table: Bool = false
    ) {
        recognize(
            image,
            options: options(
                barcode: barcode, quiet: quiet, returnOnCancel: quiet, singleLine: singleLine, table: table))
    }

    private func recognize(_ image: CGImage, options: WorkflowOptions) {
        recognize([image], options: options)
    }

    func recognize(_ images: [CGImage]) {
        recognize(images, options: options(barcode: false, quiet: false, returnOnCancel: false, singleLine: nil))
    }

    func importDocument(_ data: Data) {
        nextCollectionSource = DraftSource(application: L10n.text("iPhone／iPad 文件 OCR"))
        let options = options(barcode: false, quiet: false, returnOnCancel: false, singleLine: nil)
        invalidateOperation()
        let current = token
        let cancellation = RecognitionCancellation()
        recognitionCancellation = cancellation
        activeOptions = options
        busy = true
        failed = false
        message = L10n.text("正在讀取 iPhone 圖片／掃描文件…")
        showWindow()
        operationTask = Task {
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    try ImportedDocument.pages(from: data, cancellation: cancellation)
                }.value
                guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
                recognize(.document(source), options: options)
            } catch {
                guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
                busy = false
                activeOptions = nil
                operationTask = nil
                recognitionCancellation = nil
                failed = true
                message = error.localizedDescription
            }
        }
    }

    private enum RecognitionPages: @unchecked Sendable {
        case memory([CGImage])
        case document(ImportedPageSource)
        var count: Int {
            switch self {
            case .memory(let images): return images.count
            case .document(let source): return source.count
            }
        }
        func image(at index: Int, cancellation: RecognitionCancellation) throws -> CGImage {
            try cancellation.check()
            switch self {
            case .memory(let images): return images[index]
            case .document(let source): return try source.image(at: index, cancellation: cancellation)
            }
        }
    }
    private func recognize(_ images: [CGImage], options: WorkflowOptions) {
        recognize(.memory(images), options: options)
    }
    private func recognize(_ source: RecognitionPages, options: WorkflowOptions) {
        guard source.count > 0 else { return }
        invalidateOperation()
        forgetRetainedCapture()
        activeOptions = options
        let current = token
        let cancellation = RecognitionCancellation()
        recognitionCancellation = cancellation
        let operation = recognitionOperation
        let prefix = additiveText
        busy = true
        failed = false
        message = options.recognition.kind == .barcodes ? L10n.text("正在辨認條碼…") : L10n.text("正在辨認文字…")
        if options.quiet { restoreFocus() } else { showWindow() }
        operationTask = Task {
            let result: Result<String, Error>
            var ownedImage: CGImage?
            do {
                var pages: [String] = []
                var bytes = 0
                for index in 0..<source.count {
                    try cancellation.check()
                    let (image, retained, thumbnail) = try await Task.detached(priority: .userInitiated) {
                        let image = try source.image(at: index, cancellation: cancellation)
                        let retained =
                            index == 0 && source.count == 1 && options.recognition.kind == .text
                            ? OCRImageBuffer.copy(image) : nil
                        let thumbnail = index == 0 ? CapturePreview.image(image) : nil
                        return (image, retained, thumbnail)
                    }.value
                    guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
                    if index == 0 {
                        ownedImage = retained
                        preview = thumbnail.map {
                            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                        }
                    }
                    if source.count > 1 {
                        message = L10n.text(
                            "正在辨認第 %1$@／%2$@ 頁…", String(describing: index + 1), String(describing: source.count))
                    }
                    do {
                        let text = try await operation(image, options.recognition, cancellation)
                        bytes += text.utf8.count + (pages.isEmpty ? 0 : 2)
                        guard bytes <= 1_000_000 else { throw DeskError.invalid(L10n.text("辨認文字超出 1 MB，請分批匯入。")) }
                        pages.append(text)
                    } catch RecognitionTextError.noText {
                        if source.count == 1 { throw RecognitionTextError.noText }
                    }
                }
                result = .success(pages.joined(separator: options.recognition.singleLine ? " " : "\n\n"))
            } catch {
                result = .failure(error)
            }
            guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
            busy = false
            activeOptions = nil
            operationTask = nil
            recognitionCancellation = nil
            switch result {
            case .success(let output):
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    message = L10n.text("選區內未找到文字；剪貼簿保持原狀。")
                    failed = true
                    if options.quiet { toast.show(L10n.text("未找到文字，請再試一次。"), error: true, on: captureScreen) }
                    return
                }
                do {
                    if options.recognition.kind == .table {
                        let decoded = try JSONDecoder().decode([RecognizedTable].self, from: Data(output.utf8))
                        guard !decoded.isEmpty, decoded.count <= 20 else {
                            throw DeskError.invalid(L10n.text("未找到可用表格。"))
                        }
                        for grid in decoded { try grid.validate() }
                        tables = decoded
                        tableIndex = 0
                        text = try decoded[0].delimited(separator: "\t", protectFormulas: protectTableFormulas)
                    } else {
                        let combined = try CaptureOutput.combine(
                            output, buffer: &additiveText, additive: options.append, byteLimit: 1_000_000)
                        tables = []
                        text = combined
                    }
                } catch {
                    failed = true
                    message = error.localizedDescription
                    if options.quiet { toast.show(L10n.text("累積文字已滿，請先清除累積文字。"), error: true, on: captureScreen) }
                    return
                }
                if let ownedImage {
                    retainCapture(
                        RetainedCapture(image: ownedImage, options: options, prefix: prefix, committedText: text))
                }
                if options.autoCopy { copyText(text) }
                collectionSource = options.source
                message = options.autoCopy ? L10n.text("已辨認並複製，可直接 ⌘V 貼上。") : L10n.text("辨認完成。")
                if source.count > 1 { message = L10n.text("已辨認 %1$@ 頁。", String(describing: source.count)) + message }
                if options.speech {
                    stopSpeaking()
                    speech.speak(text: text, language: options.recognition.language)
                }
                if options.quiet {
                    if options.feedback {
                        toast.show(
                            options.append ? L10n.text("已加入累積剪貼簿 · ⌘V 貼上") : L10n.text("已複製文字 · ⌘V 貼上"),
                            on: captureScreen)
                    }
                    if options.sound { NSSound(named: "Tink")?.play() }
                }
                if offerPrecision, let ownedImage, ownedImage.height < 100 || output.contains("://") { reread() }
            case .failure(let error):
                failed = true
                message = error.localizedDescription
                if options.quiet { toast.show(L10n.text("辨認失敗，請從選單查看結果。"), error: true, on: captureScreen) }
            }
        }
    }

    func cancel(show: Bool = true) {
        let options = activeOptions
        invalidateOperation()
        activeOptions = nil
        busy = false
        if show {
            failed = false
            message = L10n.text("已取消，剪貼簿保持原狀。")
            if options?.returnOnCancel == true { restoreFocus() } else { showWindow() }
        }
    }
    private func invalidateOperation() {
        token = UUID()
        operationTask?.cancel()
        operationTask = nil
        recognitionCancellation?.cancel()
        recognitionCancellation = nil
        closePanels()
        review = nil
        reviewContext = nil
        reviewImage = nil
        reviewVisible = false
        hideReviewPanel()
    }
    func rememberForegroundApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousApp = app
            nextCollectionSource = DraftSource(application: (app.localizedName ?? "CaptureText") + " · OCR")
        }
    }
    private func restoreFocus() {
        restoreForegroundApplication(previousApp)
    }
    func sendVocabularyDraft() {
        var selected = text
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.selectedRange().length > 0,
            let range = Range(editor.selectedRange(), in: editor.string)
        {
            selected = String(editor.string[range])
        }
        AppSupport.sendDraft(
            .init(
                kind: .vocabulary, text: selected, sentence: DraftContext.sentence(in: text, selected: selected),
                source: collectionSource))
    }
    func clearAdditiveBuffer() {
        if reviewVisible { cancel(show: false) }
        forgetRetainedCapture()
        if let options = activeOptions, options.append {
            cancel(show: false)
            if options.returnOnCancel { restoreFocus() }
        }
        additiveText = ""
        message = L10n.text("已清除累積文字，下次擷取重新開始；現有剪貼簿保持原狀。")
    }
    func stopSpeaking() { speech.stop() }
    private func closePanels() {
        let hadSelection = !panels.isEmpty
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        if hadSelection { NSCursor.arrow.set() }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
    func openImage(_ url: URL? = nil, table: Bool = false) {
        var target = url
        if target == nil {
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.image]
            picker.allowsMultipleSelection = false
            if picker.runModal() == .OK { target = picker.url }
        }
        guard let target else { return }
        nextCollectionSource = DraftSource(application: L10n.text("圖片 OCR"), title: target.lastPathComponent)
        cancel(show: false)
        do { recognize(try Recognition.image(from: target), table: table) } catch {
            failed = true
            message = error.localizedDescription
            showWindow()
        }
    }
    private func forgetRetainedCapture() {
        retentionTask?.cancel()
        retentionTask = nil
        retainedCapture = nil
        canReread = false
    }
    private func retainCapture(_ capture: RetainedCapture) {
        forgetRetainedCapture()
        retainedCapture = capture
        canReread = true
        retentionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.retainedCapture = nil
            self?.canReread = false
        }
    }
    func reread() {
        guard let retainedCapture, !busy else { return }
        guard retainedCapture.committedText == text else {
            message = L10n.text("結果已編輯，請重新框選以保留你的修改。")
            forgetRetainedCapture()
            return
        }
        startReview(retainedCapture, video: false)
    }
    func recognizePrecisely(_ image: CGImage) {
        beginReview(
            image, options: options(barcode: false, quiet: false, returnOnCancel: false, singleLine: nil), video: false)
    }
    private func beginReview(_ image: CGImage, options: WorkflowOptions, video: Bool) {
        guard let owned = OCRImageBuffer.copy(image) else {
            cancel(show: false)
            message = L10n.text("選區太大，請縮小至 1,600 萬像素以內。")
            failed = true
            showWindow()
            return
        }
        startReview(
            RetainedCapture(image: owned, options: options, prefix: additiveText, committedText: nil), video: video)
    }
    private func startReview(_ context: RetainedCapture, video: Bool) {
        invalidateOperation()
        forgetRetainedCapture()
        let current = token
        let cancellation = RecognitionCancellation()
        recognitionCancellation = cancellation
        activeOptions = context.options
        reviewContext = context
        busy = true
        failed = false
        reviewVisible = true
        reviewDraft = ""
        reviewStatus = L10n.text("正在精準重讀；剪貼簿保持原狀。")
        let operation = precisionOperation
        let useSecondary = secondaryEnabled && OCRModelPack.installed
        // Hide our panels while taking the additional user-requested video samples.
        hideWindow()
        operationTask = Task {
            do {
                var frames: [CGImage] = []
                var frameNotice: String?
                if video {
                    do { frames = try await videoFrames(cancellation: cancellation) } catch {
                        try cancellation.check()
                        try Task.checkCancellation()
                        frameNotice = L10n.text("影片畫面或螢幕配置已改變，改用原始選區。")
                    }
                }
                guard current == token, !Task.isCancelled else { return }
                reviewImage = NSImage(
                    cgImage: context.image, size: NSSize(width: context.image.width, height: context.image.height))
                showReviewPanel()
                var result = try await operation(context.image, context.options.recognition, cancellation)
                if let original = context.committedText {
                    // Keep the exact first output, even if Vision gives another answer on reread.
                    let raw = textForReview(context: context, combined: original)
                    if result.candidates.first?.text != raw {
                        if let first = result.candidates.first {
                            result.candidates[0] = OCRReviewCandidate(variant: .repeated, text: first.text)
                        }
                        result.candidates.insert(OCRReviewCandidate(variant: .original, text: raw), at: 0)
                    }
                }
                if let frameNotice { result.notices.append(frameNotice) }
                if !frames.isEmpty, let reference = OCRFrameFingerprint(context.image) {
                    let options = context.options.recognition
                    let original = result.original
                    let extra = try await Task.detached(priority: .userInitiated) { () -> [String] in
                        var choices: [String] = []
                        for frame in frames {
                            try cancellation.check()
                            guard let fingerprint = OCRFrameFingerprint(frame),
                                !fingerprint.identical(to: reference), fingerprint.stable(comparedTo: reference),
                                fingerprint.sharpness > reference.sharpness
                            else { continue }
                            guard
                                let document = try? Recognition.document(
                                    frame, language: options.language,
                                    words: options.words, singleLine: options.singleLine, cancellation: cancellation),
                                OCRVideoPolicy.eligible(
                                    original: original, proposed: document,
                                    originalFrame: reference, proposedFrame: fingerprint)
                            else { continue }
                            let retry = try OCRPrecision.recognize(
                                frame, options: options, baseline: document, cancellation: cancellation)
                            choices += retry.candidates.map(\.text)
                        }
                        return choices
                    }.value
                    for text in extra { result.add(text, variant: .video) }
                    result.notices.append(L10n.text("影片只比較相同文字的穩定畫面；不同字幕不會合併。"))
                }
                if useSecondary {
                    do {
                        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CaptureOCRWorker")
                        let candidate = try await SecondaryOCRWorker.recognize(
                            context.image, document: result.original,
                            language: context.options.recognition.language, executable: executable,
                            cancellation: cancellation)
                        result.add(candidate, variant: .secondary)
                    } catch {
                        try cancellation.check()
                        try Task.checkCancellation()
                        result.notices.append(error.localizedDescription)
                    }
                }
                guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
                review = result
                reviewDraft = result.candidates.first?.text ?? ""
                reviewStatus = L10n.text("請對照原圖，選擇或編輯後採用。沒有候選會自動覆蓋原文。")
                busy = false
                operationTask = nil
                recognitionCancellation = nil
            } catch {
                guard current == token, !Task.isCancelled, !cancellation.isCancelled else { return }
                busy = false
                operationTask = nil
                recognitionCancellation = nil
                reviewStatus = error.localizedDescription
                failed = true
            }
        }
    }
    private func textForReview(context: RetainedCapture, combined: String) -> String {
        guard context.options.append, !context.prefix.isEmpty,
            combined.hasPrefix(context.prefix + "\n")
        else { return combined }
        return String(combined.dropFirst(context.prefix.count + 1))
    }
    func addURLFormattingSuggestion() {
        guard var result = review, let suggestion = OCRReviewFormatting.urlSuggestion(reviewDraft) else { return }
        result.add(suggestion, variant: .urlFormatting)
        review = result
        reviewStatus = L10n.text("只移除空白，並非辨識修正；請檢查是否誤連了旁邊文字。")
    }
    func acceptReview() {
        guard !busy, reviewVisible, review != nil, let context = reviewContext,
            !reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if let committed = context.committedText, committed != text {
            reviewStatus = L10n.text("結果已編輯，請重新框選以保留你的修改。")
            return
        }
        do {
            guard reviewDraft.utf8.count <= 1_000_000 else { throw CaptureOutputError.bufferFull }
            var prefix = context.prefix
            let combined = try CaptureOutput.combine(
                reviewDraft, buffer: &prefix, additive: context.options.append, byteLimit: 1_000_000)
            let options = context.options
            // Consume the session before any observable side effect. A second click cannot append again.
            invalidateOperation()
            forgetRetainedCapture()
            activeOptions = nil
            additiveText = prefix
            text = combined
            tables = []
            collectionSource = options.source
            copyText(combined)
            message = L10n.text("已採用並複製。")
            if options.speech { speech.speak(text: combined, language: options.recognition.language) }
            restoreFocus()
        } catch { reviewStatus = error.localizedDescription }
    }
    func dismissReview() {
        cancel(show: false)
        forgetRetainedCapture()
        message = L10n.text("已取消，剪貼簿保持原狀。")
        restoreFocus()
    }
    private func videoFrames(cancellation: RecognitionCancellation) async throws -> [CGImage] {
        guard let saved = lastSelection else { throw CancellationError() }
        var frames: [CGImage] = []
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(180))
            try cancellation.check()
            let content = try await loadShareableContent()
            guard
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == saved.display
                }), screen.frame == saved.frame,
                let display = content.displays.first(where: { $0.displayID == saved.display }),
                CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor) == saved.pixels
            else { throw CancellationError() }
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(saved.pixels.width)
            config.height = Int(saved.pixels.height)
            config.showsCursor = false
            let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try cancellation.check()
            try Task.checkCancellation()
            guard CGSize(width: frame.width, height: frame.height) == saved.pixels,
                let crop = frame.cropping(to: saved.crop), let owned = OCRImageBuffer.copy(crop)
            else { throw CancellationError() }
            frames.append(owned)
        }
        return frames
    }
    func installModels() {
        guard !downloadingModels else { return }
        downloadingModels = true
        downloadTask = Task { [weak self] in
            do {
                try await OCRModelPack.shared.install { [weak self] message in
                    await self?.setModelDownloadStatus(message)
                }
                self?.modelsInstalled = OCRModelPack.installed
                self?.secondaryEnabled = true
                self?.modelDownloadStatus = L10n.text("模型已安裝；只在精準重讀時載入。")
            } catch {
                self?.modelDownloadStatus = Task.isCancelled ? L10n.text("已取消下載。") : error.localizedDescription
            }
            self?.downloadingModels = false
            self?.downloadTask = nil
        }
    }
    private func setModelDownloadStatus(_ message: String) { modelDownloadStatus = message }
    func cancelModelDownload() { downloadTask?.cancel() }

    func speak() {
        speech.toggle(text: text, language: language)
    }
}
