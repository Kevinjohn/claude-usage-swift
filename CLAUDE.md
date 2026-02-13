# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A native macOS menu bar app that displays Claude API usage limits and reset times. Single-file Swift application with zero external dependencies, compiled directly with `swiftc` (no SPM, no Xcode project).

## Build

```bash
./build.sh
```

This compiles `ClaudeUsage.swift` with `swiftc -O` linking the Cocoa and UserNotifications frameworks, creates the `.app` bundle structure, extracts the version from `appVersion` in the Swift source, regenerates `Info.plist`, and applies ad-hoc code signing. Output: `ClaudeUsage.app/`.

Manual build alternative:
```bash
swiftc -O -o ClaudeUsage.app/Contents/MacOS/ClaudeUsage ClaudeUsage.swift -framework Cocoa -framework UserNotifications
```

Requires macOS 12.0+, Swift 5.9+, and Xcode Command Line Tools.

## Architecture

Everything lives in `ClaudeUsage.swift` (~1690 lines), organized as:

- **Version constant**: `appVersion` — single source of truth for version string, extracted by `build.sh` into Info.plist
- **Data models** (top): `UsageResponse`, `UsageLimit`, `ExtraUsage` — Codable structs matching the Anthropic OAuth usage API response; `UsageSnapshot` for tracking usage history
- **`DisplayThresholds` enum**: caseless enum (namespace pattern) with centralised static config for color breakpoints (30/61/81/91%) and countdown detail thresholds (30/61%)
- **`UDKey` enum**: centralised `private enum UDKey` with static string constants for all UserDefaults keys, preventing typo bugs
- **Ephemeral URLSession**: module-level `urlSession` using `URLSessionConfiguration.ephemeral` to prevent disk caching of API responses
- **Cached constants**: module-level `menuBarFont` (11pt monospaced-digit), `menuItemTabLocation` (dropdown column alignment width) — avoids repeated allocation
- **`UsageError` enum**: structured error type with cases `keychainNotFound`, `keychainParseFailure`, `networkError`, `httpError`, `decodingError` — each provides a `menuBarText` (e.g. `"key?"`, `"network?"`, `"auth?"`, `"rate limit?"`) and a `description` for the dropdown menu; `menuBarColor` computed property returns `.systemRed` for HTTP 429 (rate limit) and `.systemYellow` for all other errors; `hint` property returns actionable guidance for every error type, rendered as separate menu items for multiline readability
- **Cached date formatters**: module-level `iso8601FractionalFormatter`, `iso8601Formatter`, `dateOnlyFormatter` — avoids repeated allocation of expensive formatters
- **Shared date parser**: `parseISO8601()` handles both fractional-seconds and plain ISO8601 formats using cached formatters
- **Networking (async)**: `getOAuthToken()` runs `/usr/bin/security` on a background queue via `withCheckedThrowingContinuation` with a 15s subprocess timeout to avoid blocking the main thread; `fetchUsage()` uses `urlSession.data(for:)` with a 15s request timeout — both throw `UsageError`
- **Formatting helpers**: `formatReset()`, `formatResetDate(_:hoursOnly:)`, `formatResetHoursOnly()` — convert ISO8601 timestamps to human-readable countdowns; `formatResetDate` accepts a `hoursOnly` parameter to share logic between full and abbreviated formats
- **Color helper**: `colorForPercentage()` maps usage percentage to NSColor using `DisplayThresholds` breakpoints — grey (<30%), green (30–60%), yellow (61–80%), orange (81–90%, `.systemOrange` for dark/light mode adaptation), red (91%+)
- **Snapshot helpers**: `loadSnapshots()`, `saveSnapshot(pct:)`, `computeRateString()` — track usage over time, compute %/hr rate and estimated time to limit
- **Model detection**: `readActiveModel()` reads `~/.claude.json` to find the most-used model across projects; `cachedActiveModel()` wraps it with a 5-minute cache to avoid re-parsing on every refresh; `shortModelName()` converts full model IDs (e.g. `claude-opus-4-6`) to short lowercase names (`opus`, `sonnet`, `haiku`); both functions log errors via `NSLog` for debugging
- **Update checker**: `isNewerVersion(remote:local:)` performs semantic version comparison with prefix/suffix stripping and zero-padding; `checkForUpdate()` queries the GitHub Releases API at most once per 24 hours and caches the result in UserDefaults; logs errors via `NSLog` for debugging
- **Dynamic refresh ladder**: module-level `dynamicRefreshLadder` constant `[60, 120, 300, 900]` — tiers for adaptive polling
- **AppDelegate** (main class): all stored/computed properties, `applicationDidFinishLaunching`, `applicationWillTerminate`, `startDisplayTimer()`, `handleSleep()`, `handleWake()`
- **AppDelegate extensions** (5 logical groups, each with `// MARK: -` for Xcode jump-bar navigation):
  - **Menu Construction**: `buildMenu()` — constructs the full dropdown NSMenu
  - **Refresh & Timer**: `updateIntervalMenu()`, `restartTimer()` (includes 10% timer tolerance for power efficiency), `adjustDynamicInterval(newPct:)` (core dynamic refresh logic: steps down on usage increase, steps up after 2 unchanged cycles), `updateDynamicStatusItem()`, `toggleDynamicRefresh()`, `setInterval(_:)`, `refresh()`, `updateUI(usage:)`
  - **Display**: `setMenuBarText(_:color:)` (11pt monospaced-digit font; adds a 1px rounded outline box around the menu bar text using the button's CALayer, with 50% opacity border color matching the usage color and 4pt corner radius), `setMenuBarAttributedText(_:borderColor:)` (multi-colored `NSMutableAttributedString` support for weekly/sonnet sections with independent colors), `applyMenuBarBorder(color:)` (private helper extracting shared CALayer border logic), `tabbedMenuItemString(left:right:)` (creates `NSAttributedString` with left-aligned tab stop for column-aligned reset times in dropdown), `generateMenuBarText(pct:resetString:prefix:suffix:)` (shared by `updateMenuBarText()` and `testPercentage()`), `updateMenuBarText()`, `showError(_:)` (displays colored error text in menu bar — yellow by default, red for 429 — and error hint section with actionable guidance; in test mode, preserves cached state so `clearTestDisplay()` restores instantly without an API call), `updateRelativeTime()`
  - **Alerts**: `sendResetNotification(category:)` fires a macOS notification when a usage category resets to 0%; `toggleResetNotifications()` toggles the "Notifications > Reset to 0%" menu item
  - **User Actions**: `updateHeaderFromCache()`, `openReleasesPage()`, `setMenuBarTextMode(_:)`, `updateMenuBarTextModeMenu()`, `toggleWeeklyLabel()`, `toggleSonnetLabel()`, `setWeeklyMode(_:)`, `updateWeeklyModeMenu()`, `setSonnetMode(_:)`, `updateSonnetModeMenu()`, `openDashboard()`, `copyUsage()`, `toggleLaunchAtLogin()`, `testPercentage(_:)`, `testWeekly(_:)`, `testSonnet(_:)`, `testError(_:)`, `clearTestDisplay()`, `quit()`
  - `effectiveInterval` — computed property returning `refreshInterval` when dynamic is off, or the current tier interval when on
  - `effectiveDynamicLadder` — filters `dynamicRefreshLadder` to tiers strictly less than `refreshInterval`; at idle the timer uses the user's base interval
  - `showDynamicIcon` — UserDefaults-backed toggle (default off) controlling whether the idle `↻` icon appears in the menu bar; `↑`/`↓` arrows always display regardless

Key design decisions:
- Runs as a UIElement (LSUIElement=true) — no dock icon
- Credentials come from Claude Code's Keychain entry ("Claude Code-credentials"), so Claude Code must be installed and logged in
- Refresh interval is user-configurable (1/5/15/30/60 min, default 30 min) and persisted via UserDefaults
- Menu bar shows percentage + inline countdown with adaptive detail: <30% percentage only, 30–60% adds hours, 61%+ shows full h:m countdown
- A `displayTimer` (60s, 10s tolerance) updates the countdown text and relative time between API refreshes
- Stale data indicator: appends "(stale)" to menu bar text when last successful fetch was > 2x refresh interval ago
- Usage rate tracking: snapshots stored in UserDefaults, pruned to 6h / 100 entries, cleared on reset cycle change
- Reset notifications: macOS notifications when any category drops from >0% to 0%, toggled via "Notifications > Reset to 0%" submenu (default on)
- Test Display submenu contains "Test Errors" (simulate keychain, network, auth, rate-limit, server, decoding errors), "Test 5 Hours" (preview color thresholds at 10/40/75/85/95%), "Test Weekly" (preview weekly display at 40/70/95/25%), and "Test Sonnet" (preview sonnet display at 40/70/95/25%) nested submenus; all prepend "TEST: " to the menu bar text while active; managed by `DisplayMode` enum (`.live` / `.test`) — test display persists until explicitly cleared via the Clear menu item
- "Display menu bar text" submenu with prefix options: Off (default), Claude, CC, Model Name, 5 Hour — prepends the selected label to the menu bar text (e.g. `opus: 45%`, `CC: 45%`), persisted via UserDefaults; also contains "Weekly" and "Sonnet" label toggles (below a separator) controlling whether `weekly:` / `sonnet:` text appears alongside the percentage
- "Display weekly usage" submenu with threshold modes: Off (default), Low (>30%), Medium (>60%), High (>80%), Always — when active, appends weekly usage to the menu bar (e.g. ` | weekly: 72%`) with independent color from `colorForPercentage()`; persisted via UserDefaults
- "Display sonnet usage" submenu with identical threshold modes — appends sonnet usage to the menu bar (e.g. ` | sonnet: 38%`) with independent color; persisted via UserDefaults
- Launch at Login via SMAppService (macOS 13+)
- Menu bar uses 11pt monospaced-digit system font for compact, aligned display, wrapped in a subtle 1px rounded outline box (50% opacity, 4pt corner radius) for visual distinction
- `refresh()` uses `Task {}` with async/await; UI updates run on `MainActor`
- `applicationWillTerminate` invalidates both timers and removes notification observers
- Sleep/wake awareness: observes `willSleepNotification`, `didWakeNotification`, `screensDidSleepNotification`, and `screensDidWakeNotification` to fully stop all timers during system sleep and display sleep, ensuring zero CPU/network activity when the user is away; on wake, timers restart and an immediate refresh fetches fresh data
- Timer tolerance: both timers set a `tolerance` (10s for display, 10% of interval for API refresh, minimum 10s) so macOS can coalesce wake-ups with other system activity, reducing battery impact
- Build script applies ad-hoc code signing (`codesign --sign -`); version extraction uses a robust regex and exits with an error if the version cannot be found
- Dynamic refresh: adaptive polling that speeds up when usage is increasing and slows down when idle. Uses a tier ladder [1m, 2m, 5m, 15m], with faster tiers strictly below the user's base interval. At idle (`dynamicTierIndex == nil`), falls back to the user's chosen refresh interval. Steps down on usage increase, steps up after 2 unchanged cycles. Toggle via "Dynamic refresh" in Refresh Interval submenu, persisted via UserDefaults. Resets on new reset cycle. Stale data indicator still uses user's base `refreshInterval`. `dynamicStatusIcon` tracks current state: `↑` (usage increasing, polling faster) and `↓` (polling slowing back down) always display in the menu bar; `↻` (idle at base rate) only displays when `showDynamicIcon` is enabled (default off).
- Error hints: every error type shows actionable guidance in an `errorHintItem` section between the header and usage rows (e.g. "log in at console.anthropic.com", "check your internet connection", "Anthropic API is having issues"); covers keychain, network, auth, rate-limit, server, and decoding errors; hidden automatically on successful fetch
- Auto-update checker: checks GitHub Releases API once per 24 hours (on launch and wake). Caches `latestKnownVersion` and `lastUpdateCheckTime` in UserDefaults. When a newer version exists, the dropdown header changes from "Claude Code usage:" to "Update available: vX.Y.Z" and becomes clickable (opens releases page). Logs errors via `NSLog` but never affects usage display. Self-healing: updating the app clears the banner automatically via `isNewerVersion` comparison against live `appVersion`.

## Testing

No automated test suite. Test manually by building and running the app. The app requires Claude Code to be logged in for Keychain access to work.
