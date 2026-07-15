# Changelog

All notable changes to AI Usage Bar are documented in this file.

## [Unreleased]

### Added

- Add a daily Analytics section with an hourly line chart and peak activity
  hour.
- Show Antigravity quota remaining for the 5-hour and weekly windows when
  quota data is available.
- Animate the Antigravity logo in the menu bar while an AI task is running.
- Fall back to Antigravity prompt counts when quota data is unavailable.

## [0.4.0] - 2026-07-15

### Added

- Antigravity local prompt usage tracking and cost analytics:
  - Detects Antigravity CLI history files under `~/.gemini/antigravity-cli`.
  - Tracks today's prompts and session counts.
  - Computes estimated cost using Gemini 3.5 Flash list prices (assuming 1.5K input / 800 output tokens per prompt).
  - Displays Gemini brand icon/color in the status bar and dropdown.

## [0.3.1] - 2026-07-15

### Fixed

- Point the Sparkle update feed and repository links at the renamed repo
  (`AI_Usage` → `ai-usage-bar`); the old appcast URL now 404s, so builds
  carrying it cannot auto-update. **v0.3.0 shipped with the dead feed URL —
  install this version instead.**
- Recheck an expired login every minute (instead of every 5) so the display
  recovers almost as soon as the Claude CLI writes a fresh token.

## [0.3.0] - 2026-07-15

### Added

- Show estimated cost of today's tokens per provider, priced at API list
  prices per model and shown in both THB and USD (exchange rate configurable
  in Settings).
- Diagnostics log (API calls, keychain reads, errors) with a viewer in
  Settings; stored at `~/Library/Logs/AIUsageBar/`.
- Live countdown ring in the dropdown showing seconds until the next refresh.
- Show the app version in the dropdown menu.
- Settings toggles for which Claude windows (5-hour / weekly) drive the
  menu-bar percentage.
- Surface usage-API failures in the dropdown with the cause (HTTP status /
  error) and the age of the cached data still on display.
- Persist the last good Claude limits across relaunches, so the dropdown shows
  cached data (with its age) instead of nothing while the first fetch runs or
  is rate limited.

### Changed

- Wider dropdown (300 → 380) with token stats paired two per row, roughly
  halving the menu height.
- Wider Settings window with the menu-bar options grouped on one row.
- Honor the usage API's `Retry-After` on 429: nothing refetches before the
  server-given time — not the timer, not ⌘R, not a relaunch (the penalty
  window persists to disk) — and the dropdown shows a retry countdown.

### Fixed

- Parse fractional-second `resets_at` timestamps so Claude "resets in" no
  longer shows "—".
- Cache the Claude access token in memory: the keychain is read once per
  launch (and again only after a 401) instead of on every limits poll,
  cutting password prompts dramatically.
- Never start a second limits fetch while one is blocked on the keychain
  dialog — previously each 60s tick stacked another password prompt.
- Periodic refresh keeps firing while the dropdown is open (timer moved to
  `.common` run-loop mode).
- `make-app.sh` accepts `CODESIGN_IDENTITY` (and auto-detects a local
  "AIUsageBar Signing" certificate) so builds signed with a stable identity
  keep the keychain "Always Allow" grant across updates.

## [0.2.1] - 2026-07-15

### Fixed

- Fix the bundled Sparkle framework path so the released app launches normally.

## [0.2.0] - 2026-07-15

### Added

- Add Sparkle automatic updates using signed releases and a GitHub Pages appcast.
- Add **Check for Updates…** to the menu-bar menu.

### Known issue

- This release cannot launch because the bundled Sparkle framework path is
  missing. Install v0.2.1 instead.

## [0.1.0] - 2026-07-14

### Added

- First preview release of AI Usage Bar.
- Show Claude Code and Codex token usage and rate-limit readings in the macOS
  menu bar.
