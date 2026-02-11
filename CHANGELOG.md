# Changelog

All notable changes to this project are documented here.

## [v2.2.7] - 2026-02-11

### Removed
- Disable usage alerts (macOS notifications) and hide menu item — left TODO to revisit when alerts can provide more value (e.g. predictive alerts, rate-based warnings)
- Drop UserNotifications framework link from build

## [v2.2.6] - 2026-02-11

### Changed
- Replace dynamic "Model: opus" header with static "Claude Code usage:" title and separator

### Removed
- `modelItem` property and dynamic model display in dropdown (model name still available in menu bar via "Display model name" toggle)

## [v2.2.5] - 2026-02-11

### Improved
- Extend column-aligned tab layout to Extra usage row — utilization percentage aligns with reset times above

## [v2.2.4] - 2026-02-11

### Improved
- Right-align reset times in dropdown menu — usage rows use a tabbed column layout so percentages and "(resets X)" text form clean vertical columns

## [v2.2.3] - 2026-02-11

### Improved
- Organize AppDelegate into 5 focused extensions (Menu Construction, Refresh & Timer, Display, Alerts, User Actions) for easier navigation
- Add "why" comments throughout — explain non-obvious design decisions (ephemeral session, dual ISO8601 parsers, background Process queue, one-shot test guard, cents-to-dollars conversion)
- Improve existing comments to explain intent rather than restating code

## [v2.2.2] - 2026-02-11

### Improved
- Cache `ISO8601DateFormatter` and `DateFormatter` at module level to avoid repeated allocation on every refresh cycle
- Single source of truth for version string — `appVersion` constant in Swift, extracted by `build.sh` into Info.plist
- Replace force-unwraps in `computeRateString()` with `guard let` for safer idiomatic Swift
- Extract menu construction from `applicationDidFinishLaunching` into `buildMenu()` for readability
- Build script now always regenerates Info.plist so version bumps take effect without manual deletion
- Add `.claude/` to `.gitignore`

## [v2.2.1] - 2026-02-11

### Changed
- Default refresh interval changed from 15 minutes to 30 minutes
- Dynamic refresh now relaxes back to the user's chosen base interval instead of capping at 15 minutes
- Dynamic refresh idle icon (`↻`) hidden by default; `↑` and `↓` arrows still display when active

### Added
- `showDynamicIcon` preference (default off, no menu toggle yet) to control idle icon visibility

## [v2.2.0] - 2026-02-11

### Added
- Dynamic refresh — adaptive polling that speeds up when usage is climbing and slows down when stable
- Menu bar status icons for dynamic refresh state: `↑` (usage increasing, polling faster), `↓` (polling cooling down toward base rate), `↻` (idle at base rate)
- "Current: Xm" status item in the Refresh Interval submenu showing active polling interval and direction
- Dynamic refresh toggle in the Refresh Interval submenu, persisted via UserDefaults

## [v2.1.2] - 2026-02-11

### Added
- Rewritten README with menu bar guide, feature groups, and demo GIF
- LICENSE file (MIT)
- CONTRIBUTING.md
- CODE_OF_CONDUCT.md (Contributor Covenant)
- SECURITY.md with vulnerability reporting contact
- CHANGELOG.md
- GitHub issue and PR templates

## [v2.1.1] - 2026-02-10

### Changed
- Lowercase model names in menu bar and dropdown

## [v2.1.0] - 2026-02-10

### Added
- Active model name display in menu bar and dropdown

## [v2.0.0] - 2026-02-10

### Added
- Structured error types with specific menu bar indicators (`key?`, `net?`, `auth?`, `http?`, `json?`)
- Usage alerts — push notifications at 80% and 90% thresholds
- Usage rate tracking (`%/hr`) with estimated time to limit
- Hover countdown with typewriter animation

### Fixed
- Crash when API returns null `resets_at`

## [v1.1.0] - 2026-02-08

### Added
- Configurable refresh intervals (1, 5, 15, 30, 60 min)

## [v1.0.0] - 2026-02-08

### Added
- Initial release
- Live usage percentage in menu bar with color-coded status
- 5-hour and weekly limit display
- Keychain-based authentication via Claude Code credentials

[v2.2.3]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.3
[v2.2.2]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.2
[v2.2.1]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.1
[v2.2.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.0
[v2.1.2]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.2
[v2.1.1]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.1
[v2.1.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.0
[v2.0.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.0.0
[v1.1.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v1.1.0
[v1.0.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v1.0.0
