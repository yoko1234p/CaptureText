import AppKit
import CaptureCore
import DeskCore
import SwiftUI

@MainActor final class CapturePrecisionPanel: NSObject, NSWindowDelegate {
    private let model: CaptureModel
    private var window: NSPanel?
    init(model: CaptureModel) { self.model = model }
    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 530),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L10n.text("CaptureText · 精準重讀")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentMinSize = NSSize(width: 420, height: 400)
            panel.contentView = NSHostingView(rootView: CapturePrecisionView(model: model))
            panel.delegate = self
            panel.setAccessibilityIdentifier("capture.precision.panel")
            window = panel
        }
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            var rect = window.frame
            rect.size.width = min(rect.width, frame.width)
            rect.size.height = min(rect.height, frame.height)
            rect.origin.x = min(max(frame.minX, NSEvent.mouseLocation.x - rect.width / 2), frame.maxX - rect.width)
            rect.origin.y = min(max(frame.minY, NSEvent.mouseLocation.y - rect.height), frame.maxY - rect.height)
            window.setFrame(rect, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.dismissReview()
        return false
    }
}

struct CapturePrecisionView: View {
    @ObservedObject var model: CaptureModel
    @State private var selected: UUID?
    @State private var zoom = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = model.reviewImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.none)
                        .frame(width: image.size.width * (zoom ? 2 : 1), height: image.size.height * (zoom ? 2 : 1))
                }.frame(height: 100).background(.black.opacity(0.06))
                Toggle(L10n.text("原圖放大兩倍"), isOn: $zoom).toggleStyle(.checkbox).font(.caption)
            }
            Text(model.reviewStatus).font(.callout).accessibilityIdentifier("capture.precision.status")
            if let review = model.review {
                Text(L10n.text("原始辨識")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(review.candidates.first?.text ?? "").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 60)
                Picker(L10n.text("候選"), selection: $selected) {
                    ForEach(review.candidates) { candidate in
                        Text(candidate.variant.title).tag(Optional(candidate.id))
                    }
                }.onChange(of: selected) { _, id in
                    if let candidate = review.candidates.first(where: { $0.id == id }) {
                        model.reviewDraft = candidate.text
                    }
                }.accessibilityIdentifier("capture.precision.candidates")
                TextEditor(text: $model.reviewDraft).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70).border(.quaternary).accessibilityIdentifier("capture.precision.edit")
                if let raw = review.candidates.first?.text, raw != model.reviewDraft {
                    ScrollView {
                        Text(highlighted(raw: raw, draft: model.reviewDraft)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 45).accessibilityLabel(L10n.text("與原文不同的範圍"))
                }
                if !review.notices.isEmpty {
                    ScrollView {
                        Text(review.notices.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: 50)
                }
                Button(L10n.text("建立移除網址空白的候選")) { model.addURLFormattingSuggestion() }
                    .disabled(OCRReviewFormatting.urlSuggestion(model.reviewDraft) == nil).font(.caption)
            } else {
                Spacer()
                ProgressView().opacity(model.busy ? 1 : 0)
                Spacer()
            }
            HStack {
                Button(L10n.text("取消")) { model.dismissReview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("採用並複製")) { model.acceptReview() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(
                        model.busy || model.review == nil
                            || model.reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("capture.precision.accept")
            }
        }.padding(16).onChange(of: model.review?.candidates.first?.id) { _, id in selected = id }
    }
    private func highlighted(raw: String, draft: String) -> AttributedString {
        let clipped = String(draft.prefix(4096))
        let text = NSMutableAttributedString(string: clipped)
        if let range = OCRReviewFormatting.changedRange(original: String(raw.prefix(4096)), candidate: clipped),
            range.length > 0, let safe = Range(range, in: clipped)
        {
            text.addAttribute(
                .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: NSRange(safe, in: clipped))
        }
        return AttributedString(text)
    }
}
