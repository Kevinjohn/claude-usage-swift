# Changelog

All notable changes to this project are documented here.

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

[v2.2.1]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.1
[v2.2.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.2.0
[v2.1.2]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.2
[v2.1.1]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.1
[v2.1.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.1.0
[v2.0.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v2.0.0
[v1.1.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v1.1.0
[v1.0.0]: https://github.com/Kevinjohn/claude-usage-swift/releases/tag/v1.0.0
