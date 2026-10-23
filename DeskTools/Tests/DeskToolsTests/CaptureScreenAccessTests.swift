import AppKit
import ScreenCaptureKit
import XCTest

@testable import CaptureText

final class CaptureScreenAccessTests: XCTestCase {
    func testSuccessfulScreenCaptureKitCheckOverridesStaleLegacyPreflight() async {
        await MainActor.run {
            _ = NSApplication.shared
        }
        let access = await MainActor.run { CaptureScreenAccess(preflight: { false }, verify: {}) }
        await access.check()
        await MainActor.run {
            XCTAssertEqual(access.state, .allowed)
            access.refresh()
            XCTAssertEqual(access.state, .allowed)
        }
    }

    func testPermissionRevocationAfterApprovalInvalidatesTheSuccessfulState() async {
        let access = await MainActor.run { CaptureScreenAccess(preflight: { true }, verify: {}) }
        await MainActor.run {
            XCTAssertEqual(access.state, .allowed)
            XCTAssertTrue(access.handle(Self.denied))
            XCTAssertEqual(access.state, .denied)
            let denied = CaptureScreenAccess(preflight: { false }, verify: {})
            XCTAssertTrue(denied.handle(Self.denied))
            denied.refresh()
            XCTAssertEqual(denied.state, .denied, "Window activation must not remove the permission repair buttons")
        }
    }

    func testDeniedAndUnrelatedCaptureErrorsRemainDistinct() async {
        let denied = await MainActor.run {
            CaptureScreenAccess(preflight: { false }, verify: { throw Self.denied })
        }
        await denied.check()
        await MainActor.run { XCTAssertEqual(denied.state, .denied) }
        let other = await MainActor.run {
            CaptureScreenAccess(preflight: { false }, verify: { throw NSError(domain: "Fixture", code: 7) })
        }
        await other.check()
        await MainActor.run {
            guard case .unavailable = other.state else {
                return XCTFail("A generic failure is not a permission denial")
            }
            XCTAssertFalse(other.handle(NSError(domain: "Fixture", code: -3801)))
        }
    }

    func testUnderlyingPermissionDenialIsRecognizedWithoutFollowingUnboundedErrorChains() async {
        await MainActor.run {
            let error = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: Self.denied])
            XCTAssertTrue(CaptureScreenAccess.isDenied(error))
            XCTAssertFalse(CaptureScreenAccess.isDenied(NSError(domain: SCStreamErrorDomain, code: -3802)))
        }
    }

    func testConcurrentRechecksDoNotIssueDuplicateSystemRequests() async {
        let fixture = await MainActor.run { PermissionCheckFixture() }
        let access = await MainActor.run {
            CaptureScreenAccess(preflight: { false }, verify: { await fixture.wait() })
        }
        let first = Task { await access.check() }
        while await MainActor.run(body: { fixture.calls == 0 }) { await Task.yield() }
        await access.check()
        await MainActor.run {
            XCTAssertEqual(fixture.calls, 1)
            fixture.finish()
        }
        await first.value
        await MainActor.run { XCTAssertEqual(access.state, .allowed) }
    }

    func testFailedSystemSettingsLaunchGivesActionableFeedback() async {
        await MainActor.run {
            let access = CaptureScreenAccess(preflight: { false }, verify: {}, openSettings: { false })
            access.showSettings()
            guard case .unavailable(let message) = access.state else { return XCTFail("Expected launch error") }
            XCTAssertTrue(message.contains("系統設定"))
        }
    }

    func testCaptureReachesScreenCaptureKitEvenWhenLegacyPreflightIsFalse() async throws {
        let domain = "CaptureScreenAccessTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let model = try await MainActor.run {
            let access = CaptureScreenAccess(preflight: { false }, verify: {})
            let model = CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)), screenAccess: access)
            model.loadShareableContent = { throw Self.denied }
            model.capture()
            XCTAssertTrue(model.busy, "A false legacy check must not return before the actual API request")
            return model
        }
        try await Task.sleep(for: .milliseconds(300))
        await MainActor.run {
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.failed)
            XCTAssertEqual(model.screenAccess.state, .denied)
            XCTAssertEqual(model.message, CaptureScreenAccess.recoveryMessage)
            model.cancel(show: false)
        }
    }

    private static var denied: NSError { NSError(domain: SCStreamErrorDomain, code: -3801) }
}

@MainActor private final class PermissionCheckFixture {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
