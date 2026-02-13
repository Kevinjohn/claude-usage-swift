# Claude Usage — macOS Menu Bar App

A native macOS menu bar app that shows your Claude API usage, reset countdowns, and rate tracking at a glance.

![Version](https://img.shields.io/github/v/release/Kevinjohn/claude-usage-swift)
![License](https://img.shields.io/github/license/Kevinjohn/claude-usage-swift)
![Release Date](https://img.shields.io/github/release-date/Kevinjohn/claude-usage-swift)

![macOS](https://img.shields.io/badge/macOS-12.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![Dependencies](https://img.shields.io/badge/Dependencies-None-brightgreen)
![Memory](https://img.shields.io/badge/RAM-~50MB-green)

## Screenshots

![Menu bar showing usage percentage with model name](screenshot-menubar.png)

![Dropdown menu with usage breakdown and options](screenshot-menu-open.png)

## Features

**Menu Bar Display**
- Live usage percentage with color-coded status
- Adaptive countdown — low usage shows percentage only, moderate adds hours, high shows full h:m countdown
- Stale data indicator when the last fetch exceeds 2x the refresh interval
- Configurable prefix text (Off, Claude, CC, Model Name, 5 Hour) — e.g. `opus: 45% / 2h 30m`
- Optional weekly and sonnet usage alongside 5-hour — e.g. `45% | weekly: 72% | sonnet: 38%`
- Each section independently color-coded to match usage thresholds

**Usage Tracking**
- 5-hour session usage with reset countdown
- Weekly limits with reset date
- Sonnet-specific weekly limit tracking
- Extra/pay-as-you-go spending (`$XX/$YY (ZZ%)`)

**Smart Details**
- Usage rate display (`~X%/hr`) with estimated time to limit
- Active model detection from `~/.claude.json`
- Relative "last updated" timestamp (`Updated just now`, `3m ago`, etc.)

**Alerts**
- Reset notification — macOS push notification when any usage category resets to 0%
- Toggle via Notifications > Reset to 0% submenu (on by default)

**Preferences**
- Refresh interval: 1, 5, 15, 30, or 60 minutes (default: 30 min)
- Dynamic refresh — adaptive polling that speeds up when usage is climbing and slows back down when stable, with status icons in the menu bar (`↑` increasing, `↓` cooling down)
- Launch at Login (macOS 13+, via SMAppService)
- Display menu bar text — prefix options: Off, Claude, CC, Model Name, 5 Hour
- Display weekly/sonnet usage — show in menu bar with threshold modes: Off, Low (>30%), Medium (>60%), High (>80%), Always
- Label toggles — show or hide `weekly:` / `sonnet:` label text in the menu bar

**Utilities**
- Copy all usage stats to clipboard
- Open Anthropic usage dashboard
- Test Display mode — preview color thresholds, error states, weekly display, and sonnet display

**Lightweight**
- Single Swift file, zero dependencies, no Xcode project
- Compiled with `swiftc`, ad-hoc signed
- ~50 MB RAM footprint

## Requirements

- macOS 12.0+
- [Claude Code](https://claude.ai/code) installed and logged in

## Install

### Download Release

1. Download `ClaudeUsage.app.zip` from [Releases](https://github.com/Kevinjohn/claude-usage-swift/releases)
2. Unzip and drag to `/Applications`
3. Double-click to run
4. If macOS blocks it: **System Settings > Privacy & Security > Open Anyway**

### Build from Source

```bash
git clone https://github.com/Kevinjohn/claude-usage-swift.git
cd claude-usage-swift
./build.sh
open ClaudeUsage.app
```

Or manually:

```bash
swiftc -O -o ClaudeUsage.app/Contents/MacOS/ClaudeUsage ClaudeUsage.swift -framework Cocoa -framework UserNotifications
open ClaudeUsage.app
```

## How It Works

The app reads Claude Code's OAuth credentials from the macOS Keychain and queries the Anthropic usage API. 
No tokens are consumed — the usage endpoint is free.

1. Reads token from Keychain (`Claude Code-credentials`)
2. Calls `api.anthropic.com/api/oauth/usage`
3. Parses utilization percentages and reset times
4. Displays in the menu bar and dropdown

## Menu Bar Guide

### Color Thresholds

| Color  | Usage Range | Meaning         |
|--------|-------------|-----------------|
| Grey   | 0–29%       | Low usage       |
| Green  | 30–60%      | Moderate usage  |
| Yellow | 61–80%      | Elevated usage  |
| Orange | 81–90%      | High usage      |
| Red    | 91–100%     | Near limit      |

### Adaptive Display

The menu bar adjusts detail based on how close you are to your limit:

| Usage Range | Display                | Example              |
|-------------|------------------------|----------------------|
| < 30%       | Percentage only        | `45%`                |
| 30–60%      | Percentage + hours     | `45% / 2h`          |
| 61%+        | Percentage + full time | `78% / 2h 30m`      |

With a prefix enabled (e.g. Model Name), the prefix is prepended: `opus: 45% / 2h 30m`

With weekly or sonnet display enabled, additional sections appear with independent colors: `45% / 2h | weekly: 72% | sonnet: 38%`

### Dynamic Refresh Icons

When dynamic refresh is enabled, a trailing icon shows the current polling state:

| Icon | Meaning | Detail |
|------|---------|--------|
| `↑`  | Increasing | Usage went up — polling faster |
| `↓`  | Cooling down | Usage stable, polling slowing back toward base rate |
| `↻`  | Idle | Back at base refresh interval |

Examples: `47% ↑`, `opus: 72% / 3h 12m ↓`, `45% ↻`

## Error Indicators

If something goes wrong, the menu bar shows a short code instead of usage:

| Indicator | Meaning                                                    |
|-----------|------------------------------------------------------------|
| `key?`    | Keychain entry not found — Claude Code not installed or not logged in |
| `network?`| Network error — check your internet connection             |
| `auth?`   | Authentication failed (HTTP 401/403) — try logging into Claude Code again |
| `http?`   | Other HTTP error from Anthropic API                        |
| `json?`   | API response could not be decoded                          |

Click the menu bar item to see a detailed error message in the dropdown.

## Troubleshooting

### App won't open (macOS security)

Go to **System Settings > Privacy & Security**, find "ClaudeUsage was blocked", and click **Open Anyway**.

### Build fails

Ensure Xcode Command Line Tools are installed:

```bash
xcode-select --install
```

## Acknowledgements

Built on the original work by [cfranci](https://github.com/cfranci) ([claude-usage-swift](https://github.com/cfranci/claude-usage-swift)).

## License

[MIT](LICENSE)
