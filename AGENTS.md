# CCSwitcher Agent Guidelines

**Rules**:
- `project.yml` is the ONLY source of truth. NEVER edit `.pbxproj` or `Info.plist` directly. Run `xcodegen generate` after changes.
- `CCSwitcher.xcodeproj` is disposable (git-ignored).
- User-visible fixes are not done until the app is compiled, copied to `/Applications/CCSwitcher.app`, and relaunched. Do this after every completed change unless the user explicitly says not to.
- On this Mac, full Xcode/xcodebuild may be unavailable (`xcode-select` can point at Command Line Tools only). For source-only app changes, use the manual `swiftc` install flow in `BUILD_GUIDE.md` instead of editing generated project files or hand-writing an `Info.plist`.

**App**: Minimalist macOS menu bar app for managing/switching Claude Code accounts.
**Features**: Terminal-free login (Process/Pipe interception), zero-interaction token refresh (`security` CLI workaround), API usage tracking.

**Architecture & Files**:
- **Docs**: `ARCHITECTURE.md` (token flow), `BUILD_GUIDE.md`, `project.yml` (Xcode config).
- **Entry**: `CCSwitcherApp.swift` (MenuBarExtra, lifecycle), `AppState.swift` (@MainActor state).
- **Services**: 
  - `ClaudeService.swift`: Wraps `claude` CLI (auth/status).
  - `KeychainService.swift`: Manages OAuth tokens via `/usr/bin/security`.
  - `*Parser.swift`: Parses `~/.claude/` JSON caches (Activity/Cost/Stats).
- **Models**: `Account.swift`, `*Data.swift` (usage/cost/activity).
- **Views**: `MainMenuView.swift` (dropdown), `SettingsView.swift` (native window), `HiddenWindowView.swift` (LSUIElement keepalive workaround).
