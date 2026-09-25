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

    // -------------------------------------------------------------------
    // Screen blanking — ports `fleet blank` / `fleet watch` from the tmux
    // CLI (bin/fleet.js) verbatim: same idle-time source, same commands,
    // same state-machine thresholds, so the two stay interchangeable.
    // Blanking is always EXPLICIT (a button, or the idle timer below) —
    // this never forces the display off just because a power mode is set.
    // -------------------------------------------------------------------

    private static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Real macOS idle time (seconds since the last key/mouse event), from
    /// the same `ioreg` HIDIdleTime source `fleet.js`'s `idleSeconds()`
    /// reads — not a heuristic, not something Fleet tracks itself.
    static func idleSeconds() -> Double {
        let out = run("/bin/sh", ["-c", "ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF/1000000000; exit}'"])
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Blanks the display right now (`pmset displaysleepnow` — the exact
    /// command `fleet blank` runs). Any key or mouse movement wakes it;
    /// window/screen arrangement is untouched.
    static func blankNow() { _ = run("/usr/bin/pmset", ["displaysleepnow"]) }

    /// A brief "user is active" pulse that wakes a blanked display, mirroring
    /// `fleet watch`'s own wake call exactly.
    static func wakeNudge() { _ = run("/usr/bin/caffeinate", ["-u", "-t", "1"]) }

    /// The exact decision `fleet watch`'s loop makes each tick — pulled out
    /// as a pure function (no shell calls, no timers) so it can be unit
    /// tested without ever touching the real display. See hard-test.sh for
    /// why the real blank/wake calls themselves are a "test by hand" item.
    static func nextBlankState(blanked: Bool, idleSeconds: Double, anyWaiting: Bool, thresholdSeconds: Double) -> Bool {
        if blanked && anyWaiting { return false }                                   // something needs you -> wake
        if !blanked && idleSeconds >= thresholdSeconds && !anyWaiting { return true } // idle long enough -> blank
        if blanked && idleSeconds < 5 { return false }                              // real activity resumed -> wake
        return blanked
    }
}
