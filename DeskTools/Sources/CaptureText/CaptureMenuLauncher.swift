import AppKit

enum CaptureRegionRequest: Equatable {
    case precise, reread, video, text, withLineBreaks, withoutLineBreaks, repeatSelection, barcodes

    @MainActor func begin(on model: CaptureModel) {
        switch self {
        case .precise: model.capture(precise: true)
        case .reread: model.reread()
        case .video: model.capture(video: true)
        case .text: model.capture()
        case .withLineBreaks: model.capture(singleLine: false)
        case .withoutLineBreaks: model.capture(singleLine: true)
        case .repeatSelection: model.capture(last: true)
        case .barcodes: model.capture(barcode: true)
        }
    }
}

/// Menu actions may arrive before or after menuDidClose. Only the default run-loop
/// mode guarantees that AppKit has finished restoring menu focus and the cursor.
@MainActor final class CaptureMenuLauncher {
    typealias Scheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    private let schedule: Scheduler
    private let begin: (CaptureRegionRequest) -> Void
    private var pending: (() -> Void)?
    private var generation = 0
    private var scheduled = false
    private(set) var isTracking = false

    init(
        schedule: Scheduler? = nil,
        begin: @escaping (CaptureRegionRequest) -> Void
    ) {
        self.schedule = schedule ?? Self.afterMenuTracking
        self.begin = begin
    }

    static func afterMenuTracking(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { action() }
        }
    }

    func menuWillOpen() { isTracking = true }

    func menuDidClose() {
        isTracking = false
        schedulePending()
    }

    func request(_ request: CaptureRegionRequest, fromMenu: Bool) {
        perform(fromMenu: fromMenu) { [begin] in begin(request) }
    }

    func perform(fromMenu: Bool, action: @escaping () -> Void) {
        if fromMenu || isTracking || scheduled {
            pending = action
            if !isTracking { schedulePending() }
        } else {
            action()
        }
    }

    func cancelPending() {
        pending = nil
        generation += 1
        scheduled = false
    }

    private func schedulePending() {
        guard pending != nil, !scheduled else { return }
        scheduled = true
        let current = generation
        schedule { [weak self] in
            guard let self, current == self.generation else { return }
            self.scheduled = false
            guard !self.isTracking, let action = self.pending else { return }
            self.pending = nil
            action()
        }
    }
}
