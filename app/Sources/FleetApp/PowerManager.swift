import Foundation
import IOKit.pwr_mgt

/// Holds a native power assertion so the display never sleeps while sessions run.
/// This is the reliable replacement for shelling out to `caffeinate`.
final class PowerManager {
    enum Mode: String, CaseIterable, Identifiable {
        case displayOn = "Display on"        // prevent display + idle sleep
        case systemOnly = "System awake"     // system stays up, display may sleep
        case off = "Off"
        var id: String { rawValue }
    }

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private(set) var mode: Mode = .off

    func apply(_ newMode: Mode) {
        guard newMode != mode else { return }
        release()
        mode = newMode
        let reason = "fleet — Claude Code sessions running" as CFString
        switch newMode {
        case .displayOn:
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        case .systemOnly:
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        case .off:
            break
        }
    }

    func release() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        mode = .off
    }

    deinit { release() }
}
