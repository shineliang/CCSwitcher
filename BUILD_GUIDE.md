# CCSwitcher - macOS Menubar App Build Guide

A step-by-step guide to building a native macOS menubar app with SwiftUI + AppKit.
This documents how CCSwitcher was created from scratch for future reference.

---

## 1. Prerequisites

- macOS 14+ (Sonoma)
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for project generation from CLI)

```bash
brew install xcodegen
```

---

## 2. Project Structure

```
CCSwitcher/
├── project.yml                    # XcodeGen project spec
├── CCSwitcher.xcodeproj/          # Generated Xcode project
├── CCSwitcher/
│   ├── CCSwitcherApp.swift        # @main App entry point with MenuBarExtra
│   ├── AppState.swift             # Central ObservableObject state manager
│   ├── Info.plist                 # App config (LSUIElement for menubar-only)
│   ├── Models/
│   │   ├── Account.swift          # Account model + AIProviderType enum
│   │   └── UsageData.swift        # Usage data models (stats cache, sessions)
│   ├── Views/
│   │   ├── MainMenuView.swift     # Main popover content
│   │   ├── UsageDashboardView.swift  # Usage stats display
│   │   ├── UsageChartView.swift   # Bar chart for daily activity
│   │   ├── AccountSwitcherView.swift # Account list + switching UI
│   │   └── SettingsView.swift     # Settings window (TabView)
│   ├── Services/
│   │   ├── KeychainService.swift  # macOS Keychain read/write
│   │   ├── ClaudeService.swift    # Claude CLI interaction
│   │   └── StatsParser.swift      # Parse ~/.claude/stats-cache.json
│   └── Resources/
│       ├── Assets.xcassets/       # App icon + accent color
│       └── CCSwitcher.entitlements
└── BUILD_GUIDE.md                 # This file
```

---

## 3. Key Concepts

### 3.1 Menubar-Only App (No Dock Icon)

Set `LSUIElement = true` in `Info.plist` to hide the app from the Dock.
The app only appears in the menubar.

```xml
<key>LSUIElement</key>
<true/>
```

### 3.2 MenuBarExtra (macOS 13+)

SwiftUI's `MenuBarExtra` scene creates a native menubar item. Use `.menuBarExtraStyle(.window)` for a popover-style window instead of a dropdown menu.

```swift
@main
struct CCSwitcherApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
```

### 3.3 Settings Window

SwiftUI provides a built-in `Settings` scene. Use `SettingsLink` from your views to open it. On macOS, this opens as a proper Preferences window.

### 3.4 Launch at Login

Use `ServiceManagement.SMAppService` (macOS 13+) for modern launch-at-login:

```swift
import ServiceManagement

// Register
try SMAppService.mainApp.register()

// Unregister
try SMAppService.mainApp.unregister()

// Check status
let enabled = SMAppService.mainApp.status == .enabled
```

---

## 4. macOS Keychain Access

Use the Security framework directly for keychain operations:

```swift
import Security

// Save
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "my-service",
    kSecAttrAccount as String: "my-account",
    kSecValueData as String: "secret".data(using: .utf8)!
]
SecItemAdd(query as CFDictionary, nil)

// Read
let readQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "my-service",
    kSecAttrAccount as String: "my-account",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
var result: AnyObject?
SecItemCopyMatching(readQuery as CFDictionary, &result)
```

Claude Code stores its OAuth token in the macOS Keychain with service name `claude-code`.

---

## 5. Running Shell Commands from Swift

To interact with CLI tools (like `claude`), use `Process`:

```swift
func runCommand(_ executable: String, args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

---

## 6. Parsing Local JSON Files

Read and parse JSON from the filesystem (e.g., `~/.claude/stats-cache.json`):

```swift
let path = NSHomeDirectory() + "/.claude/stats-cache.json"
if let data = FileManager.default.contents(atPath: path) {
    let stats = try JSONDecoder().decode(StatsCache.self, from: data)
}
```

---

## 7. XcodeGen Project Spec

Instead of manually creating `.xcodeproj`, use XcodeGen with a `project.yml`:

```yaml
name: MyApp
options:
  bundleIdPrefix: com.myapp
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
targets:
  MyApp:
    type: application
    platform: macOS
    sources:
      - path: MyApp
        excludes:
          - "Resources/**"
    resources:
      - path: MyApp/Resources/Assets.xcassets
    settings:
      base:
        INFOPLIST_FILE: MyApp/Info.plist
        GENERATE_INFOPLIST_FILE: false
```

Generate with: `xcodegen generate`

---

## 8. Building, Installing, and Relaunching

For agent work, "done" means the changed app is actually running from
`/Applications/CCSwitcher.app`. After every user-visible fix, compile, replace
the installed app, and relaunch it unless the user explicitly asks not to.

### 8.1 Preferred Build When Full Xcode Is Available

Use this path when `xcodebuild -version` works and `xcodegen` is installed.
Remember: `project.yml` is the source of truth. Do not edit `.pbxproj` or
`Info.plist` directly.

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build
APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData -name 'CCSwitcher.app' -type d 2>/dev/null | head -1)"
test -n "$APP_PATH"
pkill -x CCSwitcher 2>/dev/null || true
rm -rf /Applications/CCSwitcher.app
ditto "$APP_PATH" /Applications/CCSwitcher.app
xattr -dr com.apple.quarantine /Applications/CCSwitcher.app 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 /Applications/CCSwitcher.app
open -a /Applications/CCSwitcher.app
pgrep -af '/Applications/CCSwitcher.app/Contents/MacOS/CCSwitcher' || true
```

### 8.2 Manual Local Build When Only Command Line Tools Are Available

On this machine, `xcodebuild` can fail with:

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

For source-only fixes, use the manual `swiftc` path below. This builds the main
menu bar app for local installation. It intentionally excludes the generated
widget extension and `UpdateChecker.swift`, then supplies a tiny temporary
`UpdateChecker` stub so local testing does not depend on the full Xcode/Sparkle
project build.

Do not create or edit a tracked `Info.plist`. The plist is generated from
`project.yml`; the manual build should reuse `/tmp/ccswitcher-manual-build/Info.plist.saved`
or the currently installed `/Applications/CCSwitcher.app/Contents/Info.plist`.

```bash
set -euo pipefail

TMP_ROOT=/tmp/ccswitcher-manual-build
APP="$TMP_ROOT/CCSwitcher.app"
INFO_BACKUP="$TMP_ROOT/Info.plist.saved"

mkdir -p "$TMP_ROOT"
if [ ! -f "$TMP_ROOT/UpdateCheckerStub.swift" ]; then
  cat > "$TMP_ROOT/UpdateCheckerStub.swift" <<'EOF'
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    func checkForUpdates(manual: Bool = false) {}
}
EOF
fi

if [ ! -f "$INFO_BACKUP" ]; then
  if [ -f /Applications/CCSwitcher.app/Contents/Info.plist ]; then
    cp /Applications/CCSwitcher.app/Contents/Info.plist "$INFO_BACKUP"
  else
    echo "Missing $INFO_BACKUP and installed Info.plist" >&2
    exit 1
  fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r source_file; do
  SOURCES+=("$source_file")
done < <(find CCSwitcher Shared -name '*.swift' ! -name 'UpdateChecker.swift' ! -path '*/CCSwitcherWidget.swift' | sort)

swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0 -Xfrontend -strict-concurrency=complete "${SOURCES[@]}" "$TMP_ROOT/UpdateCheckerStub.swift"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 -Xfrontend -strict-concurrency=complete \
  "${SOURCES[@]}" "$TMP_ROOT/UpdateCheckerStub.swift" \
  -o "$APP/Contents/MacOS/CCSwitcher"

cp "$INFO_BACKUP" "$APP/Contents/Info.plist"

for lang in de en fr ja zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cp "CCSwitcher/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/Localizable.strings"
done

cp CCSwitcher/Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
cp CCSwitcher/Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
cp CCSwitcher/Resources/litellm-pricing.json "$APP/Contents/Resources/litellm-pricing.json"
cp CCSwitcher/Resources/verified-against.json "$APP/Contents/Resources/verified-against.json"

codesign --force --sign - --entitlements CCSwitcher/Resources/CCSwitcher.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf build/CCSwitcher-authfix.app build/CCSwitcher-authfix.zip
mkdir -p build
ditto "$APP" build/CCSwitcher-authfix.app
ditto -c -k --keepParent build/CCSwitcher-authfix.app build/CCSwitcher-authfix.zip
shasum -a 256 build/CCSwitcher-authfix.zip
```

Install and relaunch the manual build:

```bash
set -euo pipefail

pkill -x CCSwitcher 2>/dev/null || true
sleep 1
if pgrep -x CCSwitcher >/dev/null 2>&1; then
  pkill -9 -x CCSwitcher 2>/dev/null || true
  sleep 1
fi

rm -rf /Applications/CCSwitcher.app
ditto build/CCSwitcher-authfix.app /Applications/CCSwitcher.app
xattr -dr com.apple.quarantine /Applications/CCSwitcher.app 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 /Applications/CCSwitcher.app
open -a /Applications/CCSwitcher.app
sleep 3
pgrep -af '/Applications/CCSwitcher.app/Contents/MacOS/CCSwitcher' || true
```

Recommended post-install checks:

```bash
plutil -lint CCSwitcher/*.lproj/Localizable.strings
git diff --check
tail -n 120 "$HOME/Library/Logs/CCSwitcher-app.log"
```

---

## 9. Swift 6 Concurrency

Swift 6 enforces strict concurrency. Key patterns:

- Mark singleton services as `Sendable` (if they have only `let` properties)
- Use `@MainActor` for UI-related classes (like `AppState`)
- Use `async/await` for CLI interactions
- Use `@StateObject` for owned observable state in SwiftUI views
- Use `@EnvironmentObject` to pass state down the view hierarchy

---

## 10. Architecture Decisions

- **Provider Protocol**: `AIProviderType` enum allows future extension to Gemini, Codex, etc.
- **Account Switching**: Swap keychain tokens for the `claude-code` service entry
- **Usage Data**: Parse `~/.claude/stats-cache.json` directly (no API needed)
- **No Sandbox**: App needs filesystem + keychain access, so sandboxing is disabled
- **Auto-Refresh**: Timer-based polling of stats file (configurable interval)

---

## 11. Adding New Providers (Future)

To add Gemini or Codex support:

1. Add case to `AIProviderType` enum in `Account.swift`
2. Create a new service (e.g., `GeminiService.swift`) following `ClaudeService` pattern
3. Update `StatsParser` to read the new provider's stats format
4. Update `AppState` to handle multi-provider switching
5. Provider-specific views can be added as needed
