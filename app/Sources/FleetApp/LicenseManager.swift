import Foundation

/// Trial + license state, shared with the CLI through the same files under
/// ~/.config/fleet (trial.json, license.json) so buying once unlocks both.
/// License checks use Dodo Payments' public activate/validate endpoints (no API
/// key ships in the app). Like any client-side check this deters casual
/// sharing; it is not DRM.
enum Entitlement: Equatable {
    case pro
    case trial(daysLeft: Int)
    case free

    var isEntitled: Bool { if case .free = self { return false }; return true }
    var label: String {
        switch self {
        case .pro: return "Pro"
        case .trial(let d): return "Trial · \(d)d left"
        case .free: return "Free"
        }
    }
}

struct ProductInfo {
    var checkoutUrl: String = ""
    var apiBase: String = "https://live.dodopayments.com"
    var trialDays: Int = 14
    var freePaneLimit: Int = 3
}

enum LicenseManager {
    private static var dir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("fleet")
    }
    private static var trialURL: URL { dir.appendingPathComponent("trial.json") }
    private static var licenseURL: URL { dir.appendingPathComponent("license.json") }
    /// Present on the developer's own machine only; see README "Owner override".
    private static var ownerURL: URL { dir.appendingPathComponent("owner") }

    /// product.json is bundled into the app at build time (single source of truth
    /// shared with the CLI); FLEET_LICENSE_API overrides the API host for test mode.
    static let product: ProductInfo = {
        var p = ProductInfo()
        if let url = Bundle.main.url(forResource: "product", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            p.checkoutUrl = o["checkoutUrl"] as? String ?? ""
            p.apiBase = o["apiBase"] as? String ?? p.apiBase
            p.trialDays = o["trialDays"] as? Int ?? p.trialDays
            p.freePaneLimit = o["freePaneLimit"] as? Int ?? p.freePaneLimit
        }
        if let env = ProcessInfo.processInfo.environment["FLEET_LICENSE_API"] { p.apiBase = env }
        return p
    }()

    // MARK: local state (fast, offline)

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private static func writeJSON(_ url: URL, _ o: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? d.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // Formatters aren't Sendable, so make a fresh one per call (called rarely).
    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    private static func parseDate(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Starts the trial clock on first call. Same file/format the CLI writes.
    static func trialDaysLeft() -> Int {
        var startedAt: Date
        if let t = readJSON(trialURL), let s = t["startedAt"] as? String, let d = parseDate(s) {
            startedAt = d
        } else {
            startedAt = Date()
            writeJSON(trialURL, ["startedAt": isoString(startedAt)])
        }
        let used = Int(Date().timeIntervalSince(startedAt) / 86_400)
        return max(0, product.trialDays - used)
    }

    /// Local, offline decision. A stored license counts for 7 days after its last
    /// successful online validation (same grace window as the CLI).
    static func currentEntitlement() -> Entitlement {
        if FileManager.default.fileExists(atPath: ownerURL.path) { return .pro }
        if let lic = readJSON(licenseURL), lic["key"] as? String != nil, lic["valid"] as? Bool != false {
            let stamp = (lic["validatedAt"] as? String) ?? (lic["activatedAt"] as? String)
            if let s = stamp, let d = parseDate(s), Date().timeIntervalSince(d) < 7 * 86_400 { return .pro }
        }
        let left = trialDaysLeft()
        return left > 0 ? .trial(daysLeft: left) : .free
    }

    static var hasStoredLicense: Bool { (readJSON(licenseURL)?["key"] as? String) != nil }

    // MARK: online (Dodo public endpoints)

    private static func post(_ path: String, _ body: [String: Any]) async -> (status: Int, json: [String: Any])? {
        guard let url = URL(string: product.apiBase + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return (http.statusCode, obj)
    }

    /// Returns nil on success, or a human-readable reason on failure.
    static func activate(key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste your license key first." }
        guard let r = await post("/licenses/activate", ["license_key": key, "name": Host.current().localizedName ?? "Mac"]) else {
            return "Couldn't reach the license server. Check your connection and try again."
        }
        switch r.status {
        case 200..<300:
            let now = isoString(Date())
            var rec: [String: Any] = ["key": key, "activatedAt": now, "validatedAt": now, "valid": true]
            if let id = r.json["id"] as? String { rec["instanceId"] = id }   // never store a nil (JSONSerialization would throw)
            writeJSON(licenseURL, rec)
            return nil
        case 403: return "That key is inactive or has been revoked."
        case 404: return "Key not found. Check for typos — keys are case-sensitive."
        case 422: return "This key is already active on its maximum number of devices. Deactivate one first."
        default: return (r.json["message"] as? String) ?? "Activation failed (\(r.status))."
        }
    }

    /// Re-validates a stored license. Refreshes the offline-grace clock on success;
    /// a definitive "invalid" from the server revokes it locally. Network errors
    /// change nothing (the grace window covers them).
    static func revalidate() async {
        guard var lic = readJSON(licenseURL), let key = lic["key"] as? String else { return }
        var body: [String: Any] = ["license_key": key]
        if let inst = lic["instanceId"] as? String { body["license_key_instance_id"] = inst }
        guard let r = await post("/licenses/validate", body) else { return }
        if (200..<300).contains(r.status), (r.json["valid"] as? Bool) != false {
            lic["validatedAt"] = isoString(Date()); lic["valid"] = true
            writeJSON(licenseURL, lic)
        } else if r.status == 404 || r.status == 403 || (r.json["valid"] as? Bool) == false {
            lic["valid"] = false
            writeJSON(licenseURL, lic)
        }
    }

    /// Frees this machine's seat, then forgets the license locally.
    static func deactivate() async -> String? {
        guard let lic = readJSON(licenseURL), let key = lic["key"] as? String else { return "No license on this Mac." }
        if let inst = lic["instanceId"] as? String,
           let r = await post("/licenses/deactivate", ["license_key": key, "license_key_instance_id": inst]),
           !(200..<300).contains(r.status) {
            return "Couldn't deactivate (\(r.status)). Try again, or contact support."
        }
        try? FileManager.default.removeItem(at: licenseURL)
        return nil
    }
}
