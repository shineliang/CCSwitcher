import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published private(set) var isAuthOperationInProgress = false
    @Published private(set) var authOperationMessage: String?
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    struct ExternalAuthOverride: Equatable, Sendable {
        let sourceName: String
        let email: String
        let expectedEmail: String
        let message: String
    }

    @Published private(set) var externalAuthOverride: ExternalAuthOverride?

    // Store errors as special struct to surface in UI
    struct UsageErrorState: Sendable {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }

    private struct BackupHealth: Sendable {
        let email: String
        let backupEmail: String?
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?
    private var isRefreshing = false

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoggingIn, !isAuthOperationInProgress else {
            log.info("[refresh] Skipping: auth operation in progress")
            return
        }
        guard !isRefreshing else {
            log.info("[refresh] Skipping: refresh already in progress")
            return
        }
        isRefreshing = true
        isLoading = true
        errorMessage = nil
        defer {
            isRefreshing = false
            isLoading = false
        }

        claudeAvailable = await claudeService.isClaudeAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        if claudeAvailable {
            do {
                let expectedActiveEmail = activeAccount?.email
                let status = try await claudeService.getAuthStatus()
                await reconcileExternalAuthOverride(status: status, expectedActiveEmail: expectedActiveEmail)
                await updateActiveAccount(from: status)
            } catch {
                log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }

        // Passive token health check (no CLI calls, keychain reads only)
        await diagnoseTokenHealth()

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // JSONL parsing: walk filesystem once via the shared cache, then
        // pull aggregated outputs. The actor's executor is off the main
        // thread, so awaiting these does not block the UI.
        await SessionParseCacheV2.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
    }

    func syncToExternalAuthOverride() async {
        guard externalAuthOverride != nil else { return }
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                return
            }

            guard accounts.isEmpty || accounts.contains(where: { $0.email == email }) else {
                let format = String(localized: "Current Orca account %@ is not in CCSwitcher. Add Current Account first.", bundle: L10n.bundle)
                errorMessage = String(format: format, email)
                return
            }

            await updateActiveAccount(from: status)
            externalAuthOverride = nil
            await fetchAllAccountUsage()
            updateWidgetData()
            log.info("[externalAuth] Synced CCSwitcher to live Claude Code account \(email)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[externalAuth] Sync failed: \(error.localizedDescription)")
        }
    }

    func dismissExternalAuthOverride() {
        externalAuthOverride = nil
        log.info("[externalAuth] Dismissed external auth override notice")
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Background Work

    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            work()
        }.value
    }

    private func runAsyncBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try await work()
        }.value
    }

    // MARK: - Auth Operation Guard

    private func beginAuthOperation(_ message: String, allowBrowserLogin: Bool = false) async -> Bool {
        guard !isAuthOperationInProgress else {
            errorMessage = String(localized: "Another Claude Code auth operation is already running.", bundle: L10n.bundle)
            log.warning("[authGuard] Blocked: auth operation already running")
            return false
        }
        guard !isLoggingIn else {
            errorMessage = String(localized: "Claude Code browser login is already in progress.", bundle: L10n.bundle)
            log.warning("[authGuard] Blocked: login already running")
            return false
        }

        isAuthOperationInProgress = true
        authOperationMessage = message
        if allowBrowserLogin {
            isLoggingIn = true
        }

        // Let SwiftUI render the progress state before running process/keychain preflight.
        await Task.yield()

        let activeLoginProcesses = await runBlocking {
            ClaudeService.activeAuthLoginProcesses()
        }
        if !activeLoginProcesses.isEmpty {
            let details = activeLoginProcesses
                .map { "pid=\($0.pid) elapsed=\($0.elapsed)" }
                .joined(separator: ", ")
            log.warning("[authGuard] Blocked by running auth login process(es): \(details)")
            errorMessage = String(localized: "Claude Code auth login is still running. Finish or cancel it before switching accounts.", bundle: L10n.bundle)
            endAuthOperation()
            return false
        }

        let activeCodeSessions = await runBlocking {
            ClaudeService.activeClaudeCodeSessionProcesses()
        }
        if !activeCodeSessions.isEmpty {
            let details = activeCodeSessions
                .prefix(8)
                .map { "pid=\($0.pid) source=\($0.source) elapsed=\($0.elapsed)" }
                .joined(separator: ", ")
            log.warning("[authGuard] Proceeding while Claude Desktop Code Mode process(es) are running: \(details)")
        }

        log.info("[authGuard] Started: \(message)")
        return true
    }

    private func endAuthOperation() {
        isAuthOperationInProgress = false
        authOperationMessage = nil
        isLoggingIn = false
    }

    // MARK: - Account Management

    func addAccount() async {
        log.info("[addAccount] Starting add current account flow...")
        guard await beginAuthOperation(String(localized: "Capturing Claude Code account...", bundle: L10n.bundle)) else { return }
        defer { endAuthOperation() }

        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: accounts.isEmpty
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let accountId = account.id.uuidString
            let captured = await runBlocking {
                ClaudeService.shared.captureCurrentCredentials(forAccountId: accountId)
            }
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if accounts.isEmpty {
                account.isActive = true
                activeAccount = account
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard await beginAuthOperation(String(localized: "Waiting for Claude Code browser login...", bundle: L10n.bundle), allowBrowserLogin: true) else { return }

        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            endAuthOperation()
            return
        }

        errorMessage = nil
        var shouldRefresh = false

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let currentId = current.id.uuidString
                let backed = await runBlocking {
                    ClaudeService.shared.captureCurrentCredentials(forAccountId: currentId)
                }
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                endAuthOperation()
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, just refresh its backup
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                let existingId = accounts[existing].id.uuidString
                _ = await runBlocking {
                    ClaudeService.shared.captureCurrentCredentials(forAccountId: existingId)
                }
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                accounts[existing].orgName = status.orgName
                accounts[existing].subscriptionType = status.subscriptionType
                accounts[existing].lastUsed = Date()
                activeAccount = accounts[existing]
                saveAccounts()
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                shouldRefresh = true
                endAuthOperation()
                if shouldRefresh { await refresh() }
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let newAccountId = account.id.uuidString
            let captured = await runBlocking {
                ClaudeService.shared.captureCurrentCredentials(forAccountId: newAccountId)
            }
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                endAuthOperation()
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            shouldRefresh = true
            endAuthOperation()
            if shouldRefresh { await refresh() }
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            endAuthOperation()
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) async {
        log.info("[removeAccount] Removing account \(account.id)")

        if account.isActive, let fallback = accounts.first(where: { $0.id != account.id }) {
            log.info("[removeAccount] Active account removed; switching to \(fallback.email) before deleting backup")
            await switchTo(fallback)
            guard activeAccount?.id == fallback.id else {
                log.warning("[removeAccount] Fallback switch did not complete; keeping account to preserve live auth state")
                return
            }
        }

        let accountId = account.id.uuidString
        _ = await runBlocking {
            KeychainService.shared.removeAccountBackup(forAccountId: accountId)
        }
        accounts.removeAll { $0.id == account.id }
        if activeAccount?.id == account.id {
            activeAccount = nil
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        guard let currentActive = activeAccount, currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")
        guard await beginAuthOperation(String(localized: "Switching Claude Code account...", bundle: L10n.bundle)) else { return }

        // Pre-switch: verify target has a backup
        let targetAccountId = account.id.uuidString
        let targetHasBackup = await runBlocking {
            KeychainService.shared.getAccountBackup(forAccountId: targetAccountId) != nil
        }
        guard targetHasBackup else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            endAuthOperation()
            return
        }

        isLoading = true
        var shouldRefresh = false
        do {
            try await runAsyncBlocking {
                try await ClaudeService.shared.switchAccount(from: currentActive, to: account)
            }

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            shouldRefresh = true
            endAuthOperation()
            if shouldRefresh { await refresh() }
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            endAuthOperation()
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard await beginAuthOperation(String(localized: "Waiting for Claude Code browser login...", bundle: L10n.bundle), allowBrowserLogin: true) else { return }

        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            endAuthOperation()
            return
        }

        errorMessage = nil
        var shouldRefresh = false

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                let currentId = current.id.uuidString
                _ = await runBlocking {
                    ClaudeService.shared.captureCurrentCredentials(forAccountId: currentId)
                }
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                endAuthOperation()
                return
            }

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                if let existing = accounts.firstIndex(where: { $0.email == email }) {
                    let existingId = accounts[existing].id.uuidString
                    _ = await runBlocking {
                        ClaudeService.shared.captureCurrentCredentials(forAccountId: existingId)
                    }
                    for i in accounts.indices {
                        accounts[i].isActive = (i == existing)
                    }
                    accounts[existing].orgName = status.orgName
                    accounts[existing].subscriptionType = status.subscriptionType
                    accounts[existing].lastUsed = Date()
                    activeAccount = accounts[existing]
                    saveAccounts()
                    shouldRefresh = true
                }
                endAuthOperation()
                if shouldRefresh { await refresh() }
                return
            }

            // 4. Capture the fresh token
            let accountId = account.id.uuidString
            let captured = await runBlocking {
                ClaudeService.shared.captureCurrentCredentials(forAccountId: accountId)
            }
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                saveAccounts()
            }

            shouldRefresh = true
            endAuthOperation()
            if shouldRefresh { await refresh() }
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            errorMessage = error.localizedDescription
            endAuthOperation()
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()
        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (no silent swap — just mark expired)
        for account in accounts {
            let tokenJSON: String?
            if account.isActive {
                tokenJSON = await runBlocking {
                    KeychainService.shared.readClaudeToken()
                }
            } else {
                let accountId = account.id.uuidString
                tokenJSON = await runBlocking {
                    KeychainService.shared.getAccountBackup(forAccountId: accountId)?.token
                }
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                continue
            }
            do {
                let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
                accountUsage[account.id] = usage
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%, fable=\(usage.sevenDayFable?.utilization ?? -1)%")
            } catch ClaudeService.UsageError.expired {
                log.warning("[fetchUsage] Token expired for \(account.email)")
                if account.isActive {
                    // Active account: delegated refresh via `claude auth status` is safe (no keychain swap)
                    do {
                        let status = try await claudeService.getAuthStatus()
                        guard status.email == account.email else {
                            let actual = status.email ?? "unknown"
                            log.error("[fetchUsage] Delegated refresh returned \(actual), expected \(account.email)")
                            accountUsage[account.id] = nil
                            accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Claude Code active account changed. Refresh before switching again.", bundle: L10n.bundle))
                            continue
                        }
                        log.info("[fetchUsage] Delegated refresh completed for active account.")
                        // Re-read refreshed token and retry
                        let refreshedJSON = await runBlocking { () -> String? in
                            guard let token = KeychainService.shared.readClaudeToken(),
                                  let oauth = KeychainService.shared.readOAuthAccount() else {
                                return nil
                            }
                            let refreshedEmail = (oauth["emailAddress"]?.value as? String) ?? "?"
                            if refreshedEmail == account.email {
                                _ = KeychainService.shared.saveAccountBackup(token: token, oauthAccount: oauth, forAccountId: account.id.uuidString)
                            } else {
                                log.warning("[fetchUsage] Refreshed oauthAccount email \(refreshedEmail) does not match \(account.email); backup not overwritten")
                            }
                            return token
                        }
                        if let refreshedJSON {
                            if let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                               let usage = try? await claudeService.getUsageLimits(accessToken: refreshedToken) {
                                accountUsage[account.id] = usage
                                accountUsageErrors[account.id] = nil
                                log.info("[fetchUsage] Recovered \(account.email) via delegated refresh.")
                            }
                        }
                    } catch {
                        log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                        accountUsage[account.id] = nil
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
                    }
                } else {
                    // Non-active account: do NOT silent-swap keychain — just mark as expired.
                    // Token will be refreshed when the user explicitly switches to this account.
                    log.info("[fetchUsage] Non-active account \(account.email) token expired, skipping silent swap to avoid race condition with Claude Code CLI.")
                    accountUsage[account.id] = nil
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to this account to refresh.", bundle: L10n.bundle))
                }
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                accountUsage[account.id] = nil
                if let usageError = error as? ClaudeService.UsageError, case .network(let msg) = usageError, msg.contains("429") {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))
                } else {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() async {
        guard !accounts.isEmpty else { return }

        let activeEmail = activeAccount?.email ?? "none"
        let accountSnapshot = accounts.map { account in
            (id: account.id.uuidString, email: account.email)
        }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(accountSnapshot.count), active: \(activeEmail)")

        // Check live oauthAccount identity
        let liveEmail = await runBlocking { () -> String? in
            guard let liveOAuth = KeychainService.shared.readOAuthAccount() else {
                return nil
            }
            return (liveOAuth["emailAddress"]?.value as? String) ?? "?"
        }
        if let liveEmail {
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        let backupHealth = await runBlocking { () -> [BackupHealth] in
            accountSnapshot.map { account in
                let backup = KeychainService.shared.getAccountBackup(forAccountId: account.id)
                let backupEmail = backup.flatMap { ($0.oauthAccount["emailAddress"]?.value as? String) ?? "?" }
                return BackupHealth(email: account.email, backupEmail: backupEmail)
            }
        }
        for item in backupHealth {
            if let backupEmail = item.backupEmail {
                log.info("[diagnose] Backup [\(item.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(item.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - External Auth Managers

    private func reconcileExternalAuthOverride(status: AuthStatus, expectedActiveEmail: String?) async {
        guard status.loggedIn, let liveEmail = status.email else {
            externalAuthOverride = nil
            return
        }

        guard let expectedActiveEmail, expectedActiveEmail != liveEmail else {
            externalAuthOverride = nil
            return
        }

        let orcaActive = await runBlocking {
            OrcaAuthService.shared.activeHostAccount()
        }

        guard let orcaActive, orcaActive.email == liveEmail else {
            log.info("[externalAuth] Live account changed from \(expectedActiveEmail) to \(liveEmail), but Orca did not explain the change")
            externalAuthOverride = nil
            return
        }

        let hasKnownLiveAccount = accounts.contains(where: { $0.email == liveEmail })
        let format: String
        if hasKnownLiveAccount {
            format = String(localized: "Orca changed Claude Code from %@ to %@. CCSwitcher synced to the live account.", bundle: L10n.bundle)
        } else {
            format = String(localized: "Orca changed Claude Code from %@ to %@. Add Current Account first to track it in CCSwitcher.", bundle: L10n.bundle)
        }
        externalAuthOverride = ExternalAuthOverride(
            sourceName: "Orca",
            email: liveEmail,
            expectedEmail: expectedActiveEmail,
            message: String(format: format, expectedActiveEmail, liveEmail)
        )
        log.warning("[externalAuth] Orca host account \(orcaActive.id) changed Claude Code from \(expectedActiveEmail) to \(liveEmail)")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus) async {
        guard status.loggedIn, let email = status.email else { return }

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            activeAccount = accounts[index]
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else if accounts.isEmpty {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            activeAccount = account
            let accountId = account.id.uuidString
            _ = await runBlocking {
                ClaudeService.shared.captureCurrentCredentials(forAccountId: accountId)
            }
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }
}
