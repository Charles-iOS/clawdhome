# Changelog

## [1.1.3] - 2026-05-06

### Improvements & Fixes
- Fixed a case where importing an existing OpenClaw instance could fall back to the default port instead of the actual Gateway port.
- Detects Gateway ports from config files, LaunchAgent environment variables, launch arguments, and command lines for more accurate legacy runtime discovery.
- Refreshes port sources for imported non-managed Profiles on load so stale port values are not kept after legacy configuration changes.


## [1.1.2] - 2026-05-05

### Improvements & Fixes
- Relaxed port spacing validation when importing existing OpenClaw instances so valid existing setups are not blocked by managed-profile port rules.
- Reuses the current Gateway port from the legacy `~/.openclaw` configuration when importing, making existing runtimes easier to take over.


## [1.1.1] - 2026-04-30

### Improvements & Fixes
- Fixed a case where upgrades from older versions could get stuck during the preinstall phase.
- Improved Supervisor handoff and health recovery during upgrades, reducing cases where Gateway or Profile runtimes were not taken over correctly.
- Automatically starts the managed Profile after legacy autostart handoff, reducing the need for manual recovery after upgrades.


## [1.1.0] - 2026-04-30

### Features
- Added support for configuring multiple Feishu accounts or channels in the same environment.
- Improved discovery and management of existing OpenClaw / Gateway instances so upgrades and recovery can take over running instances more smoothly.
- Isolated Debug Run and installed production runtime environments to reduce interference between development builds and installed releases.

### Improvements & Fixes
- Improved Gateway startup, readiness checks, health state handling, and recovery to reduce false positives, stalls, and incorrect runtime reuse.
- Added initialization progress feedback so startup and recovery are easier to follow.
- Reduced startup impact from OpenClaw scans or refreshes triggered by pages such as model settings and scheduled tasks.
- Pinned the OpenClaw runtime version for more consistent packaging and runtime behavior.


## [1.0.1] - 2026-04-28

### Improvements & Fixes
- Switched the in-app update feed to `https://imp-assets.ezrpro.com/ezrworker/`.
- Updated the post-release CDN instructions to clarify the manifest, dual-architecture packages, and checksum files that must be uploaded.


## [1.0.0] - 2026-04-28

### Features
- Released the first official EZRWorker macOS desktop version for managing digital workers, workspace sessions, and the OpenClaw Gateway.
- Added setup and pairing flows for Feishu, WeCom, Telegram, and related channel integrations.
- Added model provider configuration, onboarding, role marketplace, skills management, and cron task management.
- Added in-app update checks, update prompts, and dual-architecture package distribution.

### Improvements & Fixes
- Improved Helper and Gateway startup, reconnection, health checks, and isolated runtime stability.
- Completed package build, signing, notarization, and update manifest workflows for Apple Silicon and Intel Mac.


## [1.6.0] - 2026-04-03

### Features
- Added Node toolchain diagnosis with one-click repair to quickly troubleshoot and fix gateway runtime issues

### Improvements & Fixes
- Improved app update check and upgrade progress UX


## [1.5.0] - 2026-04-02

### Features
- Added a setup wizard to guide first-time Shrimp initialization
- App update checks now run in the background for improved reliability

### Improvements & Fixes
- Refined detail window layout and overview interaction experience
- Improved upgrade notification messages
- Hardened proxy configuration and permission checks
- Improved stability of isolation environments and the initialization flow


## [1.4.0] - 2026-03-31

### Features
- Proxy settings are now automatically applied to managed users
- Added authentication assist for terminal-based flows
- Expanded role presets in the Role Center with full localization

### Improvements & Fixes
- Streamlined user onboarding with a clearer step-by-step flow
- Improved in-app update and model configuration experiences
- Universal packaging now supports both Intel and Apple Silicon
- App notarization enabled by default for improved macOS trust


## [1.3.0] - 2026-03-29

### Features
- Added Role Market for browsing and adopting preconfigured role setups
- Direct model configuration without requiring a preset
- Redesigned onboarding experience with support for cloning from existing Shrimps
- Gateway watchdog: automatically monitors and recovers crashed gateway instances

### Improvements & Fixes
- Polished onboarding and user management interaction details
- Improved in-app banner notifications
- Safer handling of user directory ownership and permissions
- Refined quick-transfer copy


## [1.2.0] - 2026-03-26

### Features
- **WeChat onboarding**: Added a guided onboarding flow for WeChat-channel Shrimps to streamline initial setup.
- **Quick file transfer in detail view**: Upload and download files directly from the Shrimp detail panel — no need to open the full file manager.
- **Terminal opens at current path**: When launching a terminal from the file manager's maintenance window, the session starts in the directory you're already browsing.
- **Model status quick command**: A new shortcut command lets you instantly check the running status of model services from the management UI.

### Improvements & Fixes
- **Init wizard stability**: Fixed intermittent freezes and unexpected navigation jumps during the Shrimp initialization flow for a smoother setup experience.
- **Homebrew permission auto-repair**: The app now detects and attempts to automatically fix Homebrew permission issues, reducing the need for manual troubleshooting.
- **Localized model labels**: Fallback model display names are now fully translated and no longer appear as raw English identifiers.
- **Log output improvements**: Refined logging behavior to produce cleaner, less noisy output.