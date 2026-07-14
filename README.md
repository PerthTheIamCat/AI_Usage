# AI Usage Bar

> See Claude Code and Codex usage before a limit surprises you.

AI Usage Bar is a small macOS menu-bar app for people who use Claude Code,
Codex, or both. It shows today's token activity and the remaining time and
percentage in each provider's active rate-limit window.

[Download a preview release](https://github.com/PerthTheIamCat/AI_Usage/releases)
· [Report an issue](https://github.com/PerthTheIamCat/AI_Usage/issues)

**Requirements:** macOS 13 or later · Apple Silicon · Claude Code and/or Codex
already installed and signed in.

## What it shows

`✳ 42%  ◇ 63%` in the menu bar means the tightest remaining limit for Claude
and Codex. Click it for the full picture:

- **Rate limits** — remaining percentage, 5-hour and weekly windows, a compact
  meter, and reset time.
- **Today's tokens** — input, output, cache, reasoning, session count, and the
  most recent model.
- **Freshness** — when a value was last updated, so an old Codex session does
  not look like a current limit reading.

No setup screen. The app detects the CLIs from `~/.claude` and `~/.codex`.

## Install and use

1. Open the [Releases](https://github.com/PerthTheIamCat/AI_Usage/releases)
   page and download the `macos-arm64.zip` file.
2. Double-click the ZIP, then move `AIUsageBar.app` to `/Applications` if you
   want to keep it there.
3. Open `AIUsageBar.app`.
   - Current preview builds use ad-hoc signing. If macOS blocks the first
     launch, Control-click the app, choose **Open**, then confirm **Open**.
4. If you use Claude Code, macOS asks whether AIUsageBar may access
   `Claude Code-credentials` in Keychain. Choose **Always Allow** to show live
   Claude limits.
5. Click the menu-bar icon whenever you want the detailed breakdown. Press
   `⌘R` or choose **Refresh Now** to request a fresh reading.
6. From version 0.2.0 onward, the app checks for updates automatically. Use
   **Check for Updates…** from the menu whenever you want to check now.

To start it automatically: **System Settings → General → Login Items → Add**
`AIUsageBar.app`.

## How data is handled

| Provider | Today's usage | Rate-limit reading |
| --- | --- | --- |
| Claude | Local Claude Code session logs | Claude usage endpoint, using the existing Keychain access token |
| Codex | Local Codex session logs | Latest `rate_limits` entry written by Codex |

The app never refreshes, rotates, or writes Claude credentials. It uses the
existing access token only to read the usage endpoint. Codex readings are local
and are only as fresh as the latest Codex session that wrote them.

Claude's usage endpoint rate-limits requests. AI Usage Bar updates token counts
every minute, polls Claude limits every five minutes, and backs off longer after
a `429`. Use **Refresh Now** sparingly.

## Limits to know

- Release builds currently target Apple Silicon (`arm64`) only.
- A Codex limit window may be stale until you open Codex again.
- When a Claude request is rate-limited, the app shows `…` until the next
  allowed refresh instead of guessing a percentage.
- Preview releases are not yet Developer ID signed or notarized. The first
  install may still need the Control-click → **Open** step above.

## Build from source

```sh
swift build -c release
./make-app.sh
open AIUsageBar.app

# Print current readings without opening the menu-bar UI
.build/release/AIUsageBar --dump
```

## Releases for maintainers

Push a version tag such as `v0.2.0`. GitHub Actions builds an Apple Silicon ZIP
and SHA-256 checksum, publishes a prerelease, then signs and deploys the
Sparkle update feed to GitHub Pages. The private Sparkle key is stored only as
the `SPARKLE_PRIVATE_KEY` repository secret; never commit it. For a tag that
already exists, run **Publish release** manually from GitHub Actions and enter
the tag name.

```sh
./make-release.sh 0.2.0 2
```

## License

[MIT](LICENSE)
