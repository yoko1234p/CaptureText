import ServiceManagement
import XCTest

@testable import CaptureText

final class CaptureLoginItemTests: XCTestCase {
    func testEnableAndDisableUseTheActualServiceState() async {
        await MainActor.run {
            var state = SMAppService.Status.notRegistered
            let item = CaptureLoginItem(
                readStatus: { state }, register: { state = .enabled }, unregister: { state = .notRegistered })
            item.setEnabled(true)
            XCTAssertTrue(item.isRegistered)
            XCTAssertEqual(item.status, .enabled)
            item.setEnabled(false)
            XCTAssertFalse(item.isRegistered)
        }
    }

    func testRejectedRegistrationDoesNotPretendStartupWasEnabled() async {
        await MainActor.run {
            let item = CaptureLoginItem(
                readStatus: { .notRegistered }, register: { throw NSError(domain: "Fixture", code: 1) })
            item.setEnabled(true)
            XCTAssertFalse(item.isRegistered)
            XCTAssertFalse(item.error.isEmpty)
        }
    }

    func testSystemApprovalIsShownAsPendingAndCanBeRemoved() async {
        await MainActor.run {
            var state = SMAppService.Status.requiresApproval
            var openedSettings = false
            let item = CaptureLoginItem(
                readStatus: { state }, unregister: { state = .notRegistered },
                openSettings: { openedSettings = true })
            XCTAssertTrue(item.isRegistered)
            XCTAssertTrue(item.summary.contains("允許"))
            item.showSettings()
            XCTAssertTrue(openedSettings)
            item.setEnabled(false)
            XCTAssertFalse(item.isRegistered)
        }
    }

    func testChangesMadeInSystemSettingsAreReflectedWithoutWritingPreferences() async {
        await MainActor.run {
            var state = SMAppService.Status.enabled
            var registerCalls = 0
            let item = CaptureLoginItem(readStatus: { state }, register: { registerCalls += 1 })
            item.setEnabled(true)
            XCTAssertEqual(registerCalls, 0)
            state = .requiresApproval
            item.refresh()
            XCTAssertEqual(item.status, .requiresApproval)
        }
    }
}
