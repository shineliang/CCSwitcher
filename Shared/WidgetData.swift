import Foundation
import Security

/// Data shared between the main app and widget via direct file in the widget's sandbox container.
///
/// The main app (non-sandboxed) writes a JSON file into the widget extension's container directory.
/// The widget (sandboxed) reads from its own Application Support, which maps to the same path.
struct WidgetAccountData: Codable {
    let email: String          // pre-obfuscated
    let displayName: String    // pre-obfuscated
    let subscriptionType: String?
    let isActive: Bool
    let sessionUtilization: Double?
    let sessionResetTime: String?
    let weeklyUtilization: Double?
    let weeklyResetTime: String?
    let extraUsageEnabled: Bool?
    let hasError: Bool
    let errorMessage: String?
}

struct WidgetData: Codable {
    let accounts: [WidgetAccountData]
    let todayCost: Double
    let conversationTurns: Int
    let activeCodingTime: String
    let linesWritten: Int
    let modelUsage: [String: Int]
    let lastUpdated: Date

    // Team-ID-prefixed App Group. macOS Sequoia (15+) prompts for App
    // Management on `group.<bundle-id>` style identifiers; the
    // `<TEAMID>.<bundle-id>` form is auto-authorized for Developer-ID-signed
    // apps without a provisioning profile and avoids the prompt entirely.
    private static let appGroupID = "584KQTRF3B.me.xueshi.ccswitcher"
    private static let fileName = "widget-data.json"

    /// Manual local builds do not contain the widget extension and have no
    /// Apple Team ID. Asking for the production App Group from such a build is
    /// treated by macOS as access to another app's data and prompts on every
    /// launch. A real Xcode/Developer-ID build has a stable team identifier and
    /// keeps the widget path enabled.
    private static var hasTeamIdentifier: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &signingInfo) == errSecSuccess,
              let info = signingInfo as? [CFString: Any],
              let teamIdentifier = info[kSecCodeInfoTeamIdentifier] as? String else {
            return false
        }
        return !teamIdentifier.isEmpty
    }

    private static var sharedContainerURL: URL? {
        guard hasTeamIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Load from the shared App Group container.
    static func load() -> WidgetData? {
        guard let containerURL = sharedContainerURL else { return nil }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    /// Save to the shared App Group container.
    func save() {
        guard let containerURL = Self.sharedContainerURL else { return }
        let fileURL = containerURL.appendingPathComponent(Self.fileName)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
