# 1.5.1

- Replace the blue icon and exchange arrows with a centered, quieter graphite-and-teal account-card mark.

# 1.5

- Replace CLI logout with local sign-out: preserve the current profile and remove only the active auth file. Modern Codex CLI logout can revoke the saved session on the server.
- Synchronize refreshed credentials every 10 seconds while the window is open and on activation. Skip unchanged snapshots and preserve newer timestamped credentials against stale imports, syncs, and manual saves.
- Add offline Session Details and Sign In Again actions under each profile menu. Expired access tokens are explained separately from revoked refresh tokens; validity is never claimed without a server check.
- Replace Cmd+N / Control+N saving with Cmd+S. Keep only Save, Import, and Sign Out Locally in the toolbar, with proper labels for overflow and accessibility.
- Move privacy, optional search (Cmd+F), and sorting to the macOS View menu. Remove Active / Switch captions and the extra current-profile checkmark.
- Redesign the app icon as two account cards with an exchange symbol.
- Update pinned GitHub Actions, run regression tests before building, verify signing and DMG checksums, and zip the app to preserve executable permissions. This workflow uploads artifacts; it does not publish releases automatically.

## Session reliability

Compared approaches in https://github.com/Fasand/codex-auth and https://github.com/frndchagas/codex-account with current upstream Codex sources:

- https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs (`run_logout` calls `logout_with_revoke`).
- https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs (expired/reused/revoked refresh errors and proactive refresh handling).
- https://learn.chatgpt.com/docs/auth (credential storage and automatic token renewal).

A working access token can temporarily hide a stale refresh token. The failure becomes visible when renewal is attempted. Saved tokens revoked by a previous logout or another client cannot be recovered by copying the same backup again. Sign in to that account again once and use the manager's local sign-out / switch thereafter. Concurrent clients or devices using copies of the same refresh token can still invalidate each other's sessions. The app does not run its own OAuth refresh loop.

13 local regression checks passed, including the explicitly supplied archive in a temporary store. Release build, signature validation, and workflow YAML parsing passed. UI checked: reduced toolbar, menu privacy toggle, icon-only switching, Cmd+S. A week-long live-session test and a remote GitHub Actions run have not been performed. The artifact is ad-hoc signed, not Developer ID notarized.

# 1.4

- Discover the renamed ChatGPT desktop app by its unchanged `com.openai.codex` bundle identifier, with verified ChatGPT.app and Codex.app fallbacks.
- Use the documented `cli_auth_credentials_store="file"` override for isolated browser sign-in.
- Preserve refreshed credentials for saved accounts before switching and exporting; save an outgoing unsaved session before replacing it. Match account identity instead of email alone, including API-key profiles.
- Validate a target before quitting the desktop app. Refuse file switching when config.toml explicitly requests keyring, auto, or ephemeral storage.
- Write credentials atomically with owner-only permissions; restore the previous auth file if index persistence fails.
- Recognize malformed and unsupported archives explicitly; accept ISO 8601 timestamps with fractional seconds; validate all archive entries before importing.
- Prevent overlapping operations and clean up a failed login process launch.
- Register shortcuts in application menus and remove the macOS New Window collision. Add Control+N as an alias for Command+N.
- Add persistent email hiding, search, explicit Active/Switch labels, an account actions menu, deletion confirmation, and a 420-point minimum window width.
- Add standalone regression tests that work with Command Line Tools without XCTest.

## Compatibility and verification

Official authentication reference: https://learn.chatgpt.com/docs/auth

Checked locally against ChatGPT desktop 26.908.40834 / bundled codex-cli 0.154.0-alpha.6.2. The installed Codex Profiles app was version 1.2; repository HEAD was version 1.3, whose importer already supports the supplied archive format.

Tests use disposable directories. The optional PROFILE_TEST_IMPORT fixture is read locally, imported into a temporary store, and removed when the test ends. No credentials belong in the repository or release artifacts.

File-based switching does not implement OS Keychain migration. Managed authentication restrictions and externally revoked/expired refresh tokens still require a compatible configuration or a new browser login. Switching while another CLI or IDE process is refreshing the same auth file can still race; close those clients first. Live switching and browser OAuth require interactive verification and are not covered by the offline tests.
