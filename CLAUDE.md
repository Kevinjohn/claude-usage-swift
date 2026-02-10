# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A native macOS menu bar app that displays Claude API usage limits and reset times. Single-file Swift application with zero external dependencies, compiled directly with `swiftc` (no SPM, no Xcode project).

## Build

```bash
./build.sh
```

This compiles `ClaudeUsage.swift` with `swiftc -O` linking the Cocoa and UserNotifications frameworks, creates the `.app` bundle structure, generates `Info.plist` if missing, and applies ad-hoc code signing. Output: `ClaudeUsage.app/`.

Manual build alternative:
```bash
swiftc -O -o ClaudeUsage.app/Contents/MacOS/ClaudeUsage ClaudeUsage.swift -framework Cocoa -framework UserNotifications
```

Requires macOS 12.0+, Swift 5.9+, and Xcode Command Line Tools.

## Architecture

Everything lives in `ClaudeUsage.swift` (~700 lines), organized as:

- **Data models** (top): `UsageResponse`, `UsageLimit`, `ExtraUsage` — Codable structs matching the Anthropic OAuth usage API response; `UsageSnapshot` for tracking usage history
- **Ephemeral URLSession**: module-level `urlSession` using `URLSessionConfiguration.ephemeral` to prevent disk caching of API responses
- **UsageError enum**: structured error type with cases `keychainNotFound`, `keychainParseFailure`, `networkError`, `httpError`, `decodingError` — each provides a `menuBarText` (e.g. `"key?"`, `"net?"`, `"auth?"`) and a `description` for the dropdown menu
- **Shared date parser**: `parseISO8601()` handles both fractional-seconds and plain ISO8601 formats in one place
- **Networking (async)**: `getOAuthToken()` runs `/usr/bin/security` on a background queue via `withCheckedThrowingContinuation` to avoid blocking the main thread; `fetchUsage()` uses `urlSession.data(for:)` — both throw `UsageError`
- **Formatting helpers**: `formatReset()`, `formatResetDate(_:hoursOnly:)`, `formatResetHoursOnly()` — convert ISO8601 timestamps to human-readable countdowns; `formatResetDate` accepts a `hoursOnly` parameter to share logic between full and abbreviated formats
- **Color helper**: `colorForPercentage()` maps usage percentage to NSColor — grey (<30%), green (30–60%), yellow (61–80%), orange (81–90%), red (91%+)
- **Snapshot helpers**: `loadSnapshots()`, `saveSnapshot(pct:)`, `computeRateString()` — track usage over time, compute %/hr rate and estimated time to limit
- **AppDelegate**: NSApplicationDelegate managing the NSStatusItem (menu bar), dropdown NSMenu, refresh timer, display timer (60s countdown updates), test display mode, launch-at-login toggle, usage alerts, rate display, stale data indicator, and `showError()` for structured error display
  - `generateMenuBarText(pct:resetString:prefix:)` — shared method for menu bar text generation used by both `updateMenuBarText()` and `testPercentage()`
  - Interval items built via loop with `item.tag = seconds` and single `setInterval(_:)` handler
  - `updateRelativeTime()` — shows "Updated just now" / "Xm ago" / "Xh Ym ago"
  - `checkThresholds(pct:)` / `sendThresholdNotification(pct:threshold:)` — fires UNNotification at 80% and 90% usage, once per reset cycle

Key design decisions:
- Runs as a UIElement (LSUIElement=true) — no dock icon
- Credentials come from Claude Code's Keychain entry ("Claude Code-credentials"), so Claude Code must be installed and logged in
- Refresh interval is user-configurable (1/5/15/30/60 min, default 15 min) and persisted via UserDefaults
- Menu bar shows percentage + inline countdown with adaptive detail: <30% percentage only, 30–60% adds hours, 61%+ shows full h:m countdown
- A `displayTimer` (60s) updates the countdown text and relative time between API refreshes
- Stale data indicator: appends "(stale)" to menu bar text when last successful fetch was > 2x refresh interval ago
- Usage rate tracking: snapshots stored in UserDefaults, pruned to 6h / 100 entries, cleared on reset cycle change
- Threshold alerts via UserNotifications at 80% and 90%, toggled via "Usage Alerts" menu item (default: off)
- Test Display submenu lets you preview color thresholds at 10/40/75/85/95%
- Launch at Login via SMAppService (macOS 13+)
- `refresh()` uses `Task {}` with async/await; UI updates run on `MainActor`
- `applicationWillTerminate` invalidates both timers
- Build script applies ad-hoc code signing (`codesign --sign -`)

## Testing

No automated test suite. Test manually by building and running the app. The app requires Claude Code to be logged in for Keychain access to work.
