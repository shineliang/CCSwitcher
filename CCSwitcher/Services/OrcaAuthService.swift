import Foundation

private let orcaAuthLog = FileLog("OrcaAuth")

/// Read-only view of Orca's managed Claude Code account selection.
///
/// CCSwitcher deliberately does not write Orca's data or keychain items. This
/// service only helps explain why the global Claude Code auth may have moved.
struct OrcaManagedClaudeAccount: Equatable, Sendable {
    let id: String
    let email: String
    let runtime: String?
}

final class OrcaAuthService: Sendable {
    static let shared = OrcaAuthService()

    private let dataURL: URL

    init(
        dataURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca/orca-data.json")
    ) {
        self.dataURL = dataURL
    }

    func activeHostAccount() -> OrcaManagedClaudeAccount? {
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: dataURL)
            let file = try JSONDecoder().decode(OrcaDataFile.self, from: data)
            guard let settings = file.settings else {
                return nil
            }

            let activeId = settings.activeClaudeManagedAccountIdsByRuntime?["host"]
                ?? settings.activeClaudeManagedAccountId
            guard let activeId else {
                return nil
            }

            guard let account = settings.claudeManagedAccounts?.first(where: { $0.id == activeId }) else {
                orcaAuthLog.warning("[activeHostAccount] Active Orca account id \(activeId) not found in claudeManagedAccounts")
                return nil
            }

            return OrcaManagedClaudeAccount(
                id: account.id,
                email: account.email,
                runtime: account.managedAuthRuntime
            )
        } catch {
            orcaAuthLog.warning("[activeHostAccount] Could not read Orca data: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct OrcaDataFile: Decodable {
    let settings: OrcaSettings?
}

private struct OrcaSettings: Decodable {
    let activeClaudeManagedAccountId: String?
    let activeClaudeManagedAccountIdsByRuntime: [String: String]?
    let claudeManagedAccounts: [OrcaAccount]?
}

private struct OrcaAccount: Decodable {
    let id: String
    let email: String
    let managedAuthRuntime: String?
}
