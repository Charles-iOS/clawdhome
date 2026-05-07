# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

EZRWorker is a **macOS native app** (Swift 5.9 / SwiftUI / macOS 14+) that securely isolates and manages multiple OpenClaw gateway instances ("Shrimps") on a single Mac using native multi-user primitives. Each Shrimp maps to a standard macOS user account with its own runtime, data, and permissions.

## Build & Development Commands

```bash
# Build (Debug) — App + Helper
make build

# Build Helper only
make build-helper

# Install helper daemon (requires sudo)
make install-helper

# Uninstall helper daemon
make uninstall-helper

# Build release archive
make build-release

# Package .pkg installer
make pkg

# Full release (pkg + version sync + release notes)
make release

# Run i18n checks (untranslated strings, placeholder consistency, legacy string usage)
make i18n-check

# View helper logs
make log-helper          # tail -f /tmp/ezrworker-helper.log

# View app logs (os_log)
make log-app

# Clean build artifacts
make clean

# Regenerate Xcode project from project.yml (requires XcodeGen)
xcodegen generate
```

There are no unit tests configured in this project.

## Architecture

### Runtime Topology (Core Design)

```
EZRWorker.app (user context, SwiftUI)
    └── XPC (NSXPCConnection, Mach service) ──→ EZRWorkerSupervisor (user LaunchAgent)
                                                   └── per-profile OpenClaw gateway instances
```

The current mainline routes gateway runtime management through the user-level supervisor. The root helper target still exists for legacy/system-level operations, but the main app UI no longer creates `HelperClient`/`ShrimpPool`/`GatewayHub`.

### Targets (defined in `project.yml`, built via XcodeGen)

| Target | Type | Bundle ID | Role |
|--------|------|-----------|------|
| `EZRWorker` | .app | `ai.ezrworker.mac` | Admin UI — SwiftUI frontend, state management, XPC client |
| `EZRWorkerSupervisor` | tool | `ai.ezrworker.mac.supervisor` | User LaunchAgent — owns profile gateway runtimes |
| `EZRWorkerHelper` | tool | `ai.ezrworker.mac.helper` | Legacy/system-level daemon — privileged user/process/file ops |

The supervisor binary and LaunchAgent plist are embedded into the app bundle via a post-build script.

### Shared Code (`Shared/`)

- `SupervisorProtocol.swift` — App↔Supervisor XPC protocol.
- `HelperProtocol.swift` — legacy/system-level helper protocol. XPC methods must use ObjC-compatible types only.
- `*Models.swift` — Codable model types shared between both targets (Dashboard, Process, File, Network, HealthCheck, CloneClaw, LocalAI).

### App Layer (`EZRWorkerApp/`)

- **Services/** — business logic and infrastructure:
  - `SupervisorClient` — XPC client for the user-level supervisor.
  - `GatewayProfileStore` / `GatewayProcessManager` — profile configuration and runtime orchestration.
  - `GatewayService` / `GatewayClient` — HTTP/WebSocket clients for communicating with running gateway instances.
  - `ProviderKeychainStore` / `UserPasswordStore` — Keychain-backed credential storage.
  - `AgentStore` / `AgentWorkspaceManager` — agent metadata, bindings, and workspace files.
- **Models/** — app-side state objects (`GlobalModelStore`, `GlobalSecretsStore`, `AccountKeychain`, `ProviderKeyConfig`).
- **Views/** — SwiftUI views. Key screens: agent grid/workspace, capabilities, channels, model config, settings, and profile terminal.

### Helper Layer (`EZRWorkerHelper/`)

- `main.swift` — daemon entry point, XPC listener setup, JSONL logging with rotation.
- **Operations/** — privileged operations organized by domain:
  - `UserManager` — create/delete macOS users via `sysadminctl`/`dscl`.
  - `GatewayManager` — start/stop/restart gateways via `launchctl`.
  - `InstallManager` — install Node.js/OpenClaw via npm.
  - `UserFileManager` — file CRUD within user home directories.
  - `ProcessManager` — list/kill user processes.
  - `ConfigWriter` — read/write OpenClaw JSON config files.
  - `DashboardCollector` / `ConnectionCollector` / `NStatCollector` — system metrics.
  - `LocalLLMManager` — manage local AI model service (omlx).
  - `ShellRunner` — generic shell command execution as specific users.

### State Management

Uses Swift `@Observable` (Observation framework) throughout. Key observable objects are injected via SwiftUI `.environment()` from `EZRWorkerApp.swift`: `GatewayProcessManager`, `GatewayService`, `AgentStore`, `AgentWorkspaceManager`, `ProviderKeychainStore`, `AuthSessionStore`, `GatewayProfileStore`, `SupervisorClient`, `UpdateChecker`, `GlobalModelStore`, and `AppLockStore`.

### Versioning

Build numbers are **auto-derived** from git commit count (`git rev-list --count HEAD`). Version format: `1.1.<commit-count>`. No manual version bumping needed.

## Localization

- Uses **Stable.xcstrings** (Apple's modern string catalog format).
- Supported languages: English + Chinese.
- CI enforcement via three Python scripts in `scripts/`:
  - `i18n_check_untranslated.py` — finds untranslated strings.
  - `i18n_ci_check.py` — validates translation completeness and placeholder consistency.
  - `i18n_forbid_legacy_t.py` — ensures no legacy `NSLocalizedString` usage.
- Run all checks: `make i18n-check`.

## Key Paths at Runtime

| Path | Purpose |
|------|---------|
| `/tmp/ezrworker-helper.log` | Helper JSONL log (2MB max, 3 rotations) |
| `/var/lib/ezrworker/` | Helper persistent state (init progress, debug flag, autostart config) |
| `~<shrimp>/.openclaw/` | Per-Shrimp OpenClaw config and data |
| `~<shrimp>/.npm-global/` | Per-Shrimp npm global install directory |

## Conventions

- Code comments and Makefile help text are in **Chinese**.
- XPC protocol changes require updating `Shared/HelperProtocol.swift` — both targets compile this file.
- The helper runs as a LaunchDaemon (`/Library/LaunchDaemons/ai.ezrworker.mac.helper.plist`). During development, use `make install-helper` to deploy it.
- JSON is the serialization format for complex data passed over XPC (encoded as String, decoded on both sides using shared Codable models).
