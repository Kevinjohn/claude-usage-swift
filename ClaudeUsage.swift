import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Version

private let appVersion = "2.6.2"

// MARK: - Usage API

struct UsageResponse: Codable {
    let five_hour: UsageLimit?
    let seven_day: UsageLimit?
    let seven_day_sonnet: UsageLimit?
    let extra_usage: ExtraUsage?
}

struct UsageLimit: Codable {
    let utilization: Double
    let resets_at: String?
}

struct ExtraUsage: Codable {
    let is_enabled: Bool
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
}

// MARK: - Display Thresholds

/// Central configuration for all percentage-based thresholds.
/// Centralised here so color, countdown, and alert boundaries stay consistent.
struct DisplayThresholds {
    // Color thresholds (menu bar text color changes at these boundaries)
    static let colorGreen  = 30   // below this: grey, at/above: green
    static let colorYellow = 61   // at/above: yellow
    static let colorOrange = 81   // at/above: orange
    static let colorRed    = 91   // at/above: red

    // Menu bar countdown detail thresholds
    static let showHoursOnly    = 30  // at/above: show hours-only countdown
    static let showFullCountdown = 61  // at/above: show full h:m countdown

}

// MARK: - Usage Snapshot

struct UsageSnapshot: Codable {
    let timestamp: TimeInterval
    let pct: Double
}

// MARK: - Ephemeral URLSession

/// Ephemeral to avoid caching OAuth tokens or usage data to disk.
private let urlSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

// MARK: - Error Handling

enum UsageError: Error, CustomStringConvertible {
    case keychainNotFound
    case keychainParseFailure
    case networkError(Error)
    case httpError(Int)
    case decodingError(Error)

    var menuBarText: String {
        switch self {
        case .keychainNotFound: return "key?"
        case .keychainParseFailure: return "key?"
        case .networkError: return "network?"
        case .httpError(let code) where code == 401 || code == 403: return "auth?"
        case .httpError(let code) where code == 429: return "rate limit?"
        case .httpError: return "http?"
        case .decodingError: return "json?"
        }
    }

    var menuBarColor: NSColor {
        switch self {
        case .httpError(let code) where code == 429: return .systemRed
        default: return .systemYellow
        }
    }

    var description: String {
        switch self {
        case .keychainNotFound:
            return "Keychain entry not found — is Claude Code installed and logged in?"
        case .keychainParseFailure:
            return "Could not parse OAuth token from Keychain"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let code) where code == 401 || code == 403:
            return "HTTP \(code) — token expired or invalid"
        case .httpError(let code):
            return "HTTP \(code) from Anthropic API"
        case .decodingError(let error):
            return "Could not decode API response: \(error.localizedDescription)"
        }
    }

    var hint: String? {
        switch self {
        case .keychainNotFound:
            return "Try: open Claude Code and log in"
        case .keychainParseFailure:
            return "Try: run `claude` in your terminal to\nrefresh your login, or reinstall Claude Code"
        case .networkError:
            return "Check your internet connection and try\nRefresh from the menu"
        case .httpError(let code) where code == 401 || code == 403:
            return "Try: log in at console.anthropic.com, or\nstart Claude Code to refresh your token"
        case .httpError(let code) where code == 429:
            return "Rate limited — wait a moment and try\nRefresh from the menu"
        case .httpError(let code) where code >= 500 && code < 600:
            return "Anthropic API is having issues —\ntry again later"
        case .httpError:
            return "Unexpected error — try Refresh from\nthe menu, or check status.anthropic.com"
        case .decodingError:
            return "The API response format may have changed —\ncheck for an app update"
        }
    }
}

// MARK: - Cached Date Formatters

private let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let dateOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

// MARK: - Shared Date Parser

/// Tries both fractional-seconds and plain ISO8601 — the API returns either format
/// depending on the endpoint, so we need to handle both.
func parseISO8601(_ string: String) -> Date? {
    if let date = iso8601FractionalFormatter.date(from: string) { return date }
    return iso8601Formatter.date(from: string)
}

// MARK: - Networking (async)

/// Reads Claude Code's OAuth token from the macOS Keychain.
/// Runs Process on a background queue because Process.run() blocks until exit.
func getOAuthToken() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                guard task.terminationStatus == 0 else {
                    continuation.resume(throwing: UsageError.keychainNotFound)
                    return
                }
                guard let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let jsonData = json.data(using: .utf8),
                      let creds = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let oauth = creds["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String else {
                    continuation.resume(throwing: UsageError.keychainParseFailure)
                    return
                }
                continuation.resume(returning: token)
            } catch {
                continuation.resume(throwing: UsageError.keychainNotFound)
            }
        }
    }
}

func fetchUsage(token: String) async throws -> UsageResponse {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        throw UsageError.networkError(URLError(.badURL))
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("ClaudeUsage-menubar/\(appVersion)", forHTTPHeaderField: "User-Agent")

    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await urlSession.data(for: request)
    } catch {
        throw UsageError.networkError(error)
    }

    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        throw UsageError.httpError(httpResponse.statusCode)
    }

    do {
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    } catch {
        throw UsageError.decodingError(error)
    }
}

// MARK: - Formatting Helpers

func formatReset(_ isoString: String) -> String {
    guard let date = parseISO8601(isoString) else { return "?" }
    return formatResetDate(date)
}

func formatResetDate(_ date: Date, hoursOnly: Bool = false) -> String {
    let diff = date.timeIntervalSince(Date())
    if diff < 0 { return "now" }

    let hours = Int(diff) / 3600
    let mins = (Int(diff) % 3600) / 60

    if hours < 24 {
        if hoursOnly && hours > 0 {
            return "\(hours)h"
        } else if hours == 0 {
            return "\(mins)m"
        } else {
            return "\(hours)h \(mins)m"
        }
    } else {
        return dateOnlyFormatter.string(from: date)
    }
}

func formatResetHoursOnly(_ isoString: String) -> String {
    guard let date = parseISO8601(isoString) else { return "?" }
    return formatResetDate(date, hoursOnly: true)
}

// MARK: - Usage Color

func colorForPercentage(_ pct: Int) -> NSColor {
    switch pct {
    case ..<DisplayThresholds.colorGreen:  return .systemGray
    case ..<DisplayThresholds.colorYellow: return .systemGreen
    case ..<DisplayThresholds.colorOrange: return .systemYellow
    case ..<DisplayThresholds.colorRed:    return NSColor(red: 0.875, green: 0.325, blue: 0.0, alpha: 1.0)
    default:                               return .systemRed
    }
}

// MARK: - Snapshot Helpers

func loadSnapshots() -> [UsageSnapshot] {
    guard let data = UserDefaults.standard.data(forKey: "usageHistory"),
          let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else {
        return []
    }
    return snapshots
}

func saveSnapshot(pct: Double) {
    var snapshots = loadSnapshots()
    let now = Date().timeIntervalSince1970
    snapshots.append(UsageSnapshot(timestamp: now, pct: pct))

    // Prune to last 6 hours, cap at 100 entries
    let sixHoursAgo = now - 6 * 3600
    snapshots = snapshots.filter { $0.timestamp >= sixHoursAgo }
    if snapshots.count > 100 {
        snapshots = Array(snapshots.suffix(100))
    }

    if let data = try? JSONEncoder().encode(snapshots) {
        UserDefaults.standard.set(data, forKey: "usageHistory")
    }
}

func computeRateString() -> String? {
    let snapshots = loadSnapshots()
    guard snapshots.count >= 2,
          let first = snapshots.first,
          let last = snapshots.last else { return nil }
    let elapsed = last.timestamp - first.timestamp
    guard elapsed >= 300 else { return nil } // Need 5+ minutes of data

    let pctDelta = last.pct - first.pct
    let hoursElapsed = elapsed / 3600
    let ratePerHour = pctDelta / hoursElapsed

    if ratePerHour <= 0 {
        return "Usage stable"
    }

    let remaining = 100.0 - last.pct
    guard remaining > 0 else {
        return String(format: "~%.0f%%/hr", ratePerHour)
    }
    let hoursToLimit = remaining / ratePerHour

    guard hoursToLimit < 100 else {
        return String(format: "~%.0f%%/hr", ratePerHour)
    }

    let hrs = Int(hoursToLimit)
    return String(format: "~%.0f%%/hr — limit in ~%dh at this pace", ratePerHour, hrs)
}

// MARK: - Model Detection

/// Finds the most-used model across all projects in ~/.claude.json
/// by summing output tokens, so the menu bar shows the relevant model.
func readActiveModel() -> String? {
    let claudeJson = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    guard let data = try? Data(contentsOf: claudeJson),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let projects = root["projects"] as? [String: Any] else {
        return nil
    }

    var modelTotals: [String: Int] = [:]
    for (_, projectValue) in projects {
        guard let project = projectValue as? [String: Any],
              let modelUsage = project["lastModelUsage"] as? [String: Any] else {
            continue
        }
        for (modelId, usageValue) in modelUsage {
            guard let usage = usageValue as? [String: Any],
                  let output = usage["outputTokens"] as? Int else {
                continue
            }
            modelTotals[modelId, default: 0] += output
        }
    }

    guard let topModel = modelTotals.max(by: { $0.value < $1.value })?.key else {
        return nil
    }
    return shortModelName(topModel)
}

func shortModelName(_ modelId: String) -> String {
    let parts = modelId.lowercased().split(separator: "-")
    let families = ["opus", "sonnet", "haiku"]
    for part in parts {
        if families.contains(String(part)) {
            return String(part)
        }
    }
    // Fallback: return first 12 chars of the ID
    return String(modelId.prefix(12))
}

// MARK: - Update Checker

/// Semantic version comparison: returns true if `remote` is newer than `local`.
/// Strips "v" prefix and any pre-release suffix (e.g. "-beta"), splits by ".",
/// compares numerically with zero-padding for unequal lengths.
func isNewerVersion(remote: String, local: String) -> Bool {
    func normalize(_ v: String) -> [Int] {
        let stripped = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let base = stripped.split(separator: "-").first.map(String.init) ?? stripped
        return base.split(separator: ".").compactMap { Int($0) }
    }
    let r = normalize(remote)
    let l = normalize(local)
    let count = max(r.count, l.count)
    for i in 0..<count {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv > lv { return true }
        if rv < lv { return false }
    }
    return false
}

/// Checks GitHub for the latest release, at most once per 24 hours.
/// On success, caches the version and timestamp in UserDefaults.
/// On any failure, returns silently without clearing cached state.
func checkForUpdate() async {
    let defaults = UserDefaults.standard
    let lastCheck = defaults.double(forKey: "lastUpdateCheckTime")
    if lastCheck > 0 && Date().timeIntervalSince1970 - lastCheck < 86400 { return }

    guard let url = URL(string: "https://api.github.com/repos/cfranci/claude-usage-swift/releases/latest") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("ClaudeUsage-menubar/\(appVersion)", forHTTPHeaderField: "User-Agent")

    guard let (data, response) = try? await urlSession.data(for: request),
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tagName = json["tag_name"] as? String else { return }

    defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheckTime")
    defaults.set(tagName, forKey: "latestKnownVersion")
}

// MARK: - Dynamic Refresh Ladder

let dynamicRefreshLadder: [TimeInterval] = [60, 120, 300, 900]  // 1m, 2m, 5m, 15m

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var timer: Timer?
    var displayTimer: Timer?

    // Cached state for menu bar display
    var fiveHourPct: Int?
    var fiveHourResetString: String?
    var testModeActive = false
    var isRefreshing = false
    var activeModelName: String?

    // Menu items
    var headerItem: NSMenuItem!
    var errorHintSeparator: NSMenuItem!
    var errorHintItems: [NSMenuItem] = []
    var fiveHourItem: NSMenuItem!
    var weeklyItem: NSMenuItem!
    var sonnetItem: NSMenuItem!
    var extraItem: NSMenuItem!
    var rateItem: NSMenuItem!
    var updatedItem: NSMenuItem!

    // Refresh interval items
    var intervalItems: [NSMenuItem] = []

    // Launch at login
    var launchAtLoginItem: NSMenuItem!

    // Menu Bar Text Prefix
    var menuBarTextItem: NSMenuItem!
    var menuBarTextModeItems: [NSMenuItem] = []
    var showWeeklyLabelItem: NSMenuItem!
    var showWeeklyLabel: Bool {
        get { UserDefaults.standard.object(forKey: "showWeeklyLabel") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showWeeklyLabel") }
    }
    var showSonnetLabelItem: NSMenuItem!
    var showSonnetLabel: Bool {
        get { UserDefaults.standard.object(forKey: "showSonnetLabel") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showSonnetLabel") }
    }
    var menuBarTextMode: String {
        get { UserDefaults.standard.string(forKey: "menuBarTextMode") ?? "off" }
        set {
            UserDefaults.standard.set(newValue, forKey: "menuBarTextMode")
            updateMenuBarTextModeMenu()
            updateMenuBarText()
        }
    }

    // Show Weekly in Menu Bar
    var showWeeklyItem: NSMenuItem!
    var weeklyModeItems: [NSMenuItem] = []
    var cachedWeeklyPct: Int?
    var showWeeklyMode: String {
        get { UserDefaults.standard.string(forKey: "showWeeklyMode") ?? "off" }
        set {
            UserDefaults.standard.set(newValue, forKey: "showWeeklyMode")
            updateWeeklyModeMenu()
            updateMenuBarText()
        }
    }

    // Show Sonnet in Menu Bar
    var showSonnetItem: NSMenuItem!
    var sonnetModeItems: [NSMenuItem] = []
    var cachedSonnetPct: Int?
    var showSonnetMode: String {
        get { UserDefaults.standard.string(forKey: "showSonnetMode") ?? "off" }
        set {
            UserDefaults.standard.set(newValue, forKey: "showSonnetMode")
            updateSonnetModeMenu()
            updateMenuBarText()
        }
    }

    // Update checker
    var latestKnownVersion: String? {
        get { UserDefaults.standard.string(forKey: "latestKnownVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "latestKnownVersion") }
    }

    // Reset notifications
    var resetNotifyItem: NSMenuItem!
    var resetNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "resetNotificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "resetNotificationsEnabled") }
    }
    var previousWeeklyPct: Int?
    var previousSonnetPct: Int?
    var previousExtraPct: Int?

    // Stale data tracking
    var lastSuccessfulFetch: Date?
    var lastUpdateTime: Date?

    // Dynamic refresh
    var dynamicRefreshItem: NSMenuItem!
    var dynamicStatusItem: NSMenuItem!
    var dynamicTierIndex: Int = 0
    var dynamicPreviousPct: Int? = nil
    var dynamicUnchangedCount: Int = 0
    var dynamicStatusIcon: String = "↻"  // ↑ usage increasing, ↓ polling slowing down, ↻ idle at base rate

    var dynamicRefreshEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dynamicRefreshEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "dynamicRefreshEnabled") }
    }

    var showDynamicIcon: Bool {
        get { UserDefaults.standard.object(forKey: "showDynamicIcon") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showDynamicIcon") }
    }

    // Only tiers faster than the user's base interval; at idle we fall back to base
    var effectiveDynamicLadder: [TimeInterval] {
        return dynamicRefreshLadder.filter { $0 < refreshInterval }
    }

    var effectiveInterval: TimeInterval {
        guard dynamicRefreshEnabled else { return refreshInterval }
        let ladder = effectiveDynamicLadder
        guard !ladder.isEmpty, dynamicTierIndex < ladder.count else { return refreshInterval }
        return ladder[dynamicTierIndex]
    }

    // Current interval in seconds
    var refreshInterval: TimeInterval = 1800 {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            updateIntervalMenu()
            restartTimer()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuBarText("...")

        // Build and attach menu
        menu = buildMenu()
        statusItem.menu = menu

        // Restore saved refresh interval
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        if stored > 0 { refreshInterval = stored }

        // Initialize dynamic refresh state
        if dynamicRefreshEnabled {
            let ladder = effectiveDynamicLadder
            dynamicTierIndex = ladder.count  // At base rate (user's interval)
            dynamicPreviousPct = nil
            dynamicUnchangedCount = 0
            dynamicStatusIcon = "↻"
        }

        // Request notification permission so reset alerts can fire
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Pause timers during system sleep and display sleep (no point polling when nobody is looking)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Update checkmarks
        updateIntervalMenu()
        updateDynamicStatusItem()

        // Initial fetch
        refresh()

        // Check for updates
        updateHeaderFromCache()
        Task {
            await checkForUpdate()
            await MainActor.run { self.updateHeaderFromCache() }
        }

        // Start timer
        restartTimer()
        startDisplayTimer()
    }

    func startDisplayTimer() {
        displayTimer?.invalidate()
        // Separate from refresh timer — updates countdown text without API calls
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateMenuBarText()
            self?.updateRelativeTime()
        }
        displayTimer?.tolerance = 10  // Let macOS coalesce with other wake-ups
    }

    @objc func handleSleep() {
        timer?.invalidate()
        timer = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    @objc func handleWake() {
        // Restart timers and fetch fresh data — the old data is stale after sleep
        restartTimer()
        startDisplayTimer()
        refresh()

        // Re-check for updates if 24h elapsed during sleep
        Task {
            await checkForUpdate()
            await MainActor.run { self.updateHeaderFromCache() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        displayTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

// MARK: - Menu Construction

extension AppDelegate {
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        headerItem = NSMenuItem(title: "Claude Code usage:", action: nil, keyEquivalent: "")
        fiveHourItem = NSMenuItem(title: "5-hour: ...", action: nil, keyEquivalent: "")
        weeklyItem = NSMenuItem(title: "Weekly: ...", action: nil, keyEquivalent: "")
        sonnetItem = NSMenuItem(title: "Sonnet: ...", action: nil, keyEquivalent: "")
        extraItem = NSMenuItem(title: "Extra: ...", action: nil, keyEquivalent: "")
        rateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        rateItem.isHidden = true
        updatedItem = NSMenuItem(title: "Updated: --", action: nil, keyEquivalent: "")

        errorHintSeparator = NSMenuItem.separator()
        errorHintSeparator.isHidden = true

        errorHintItems = (0..<4).map { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            return item
        }

        menu.addItem(headerItem)
        menu.addItem(errorHintSeparator)
        for item in errorHintItems { menu.addItem(item) }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(fiveHourItem)
        menu.addItem(rateItem)
        menu.addItem(weeklyItem)
        menu.addItem(sonnetItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(extraItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))

        // Refresh interval submenu
        let settingsMenu = NSMenu()
        let intervals: [(String, Int)] = [
            ("Every 1 minute", 60),
            ("Every 5 minutes", 300),
            ("Every 15 minutes", 900),
            ("Every 30 minutes", 1800),
            ("Every hour", 3600)
        ]
        for (title, seconds) in intervals {
            let item = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            intervalItems.append(item)
            settingsMenu.addItem(item)
        }

        settingsMenu.addItem(NSMenuItem.separator())
        dynamicRefreshItem = NSMenuItem(title: "Dynamic refresh", action: #selector(toggleDynamicRefresh), keyEquivalent: "")
        dynamicRefreshItem.target = self
        dynamicRefreshItem.state = dynamicRefreshEnabled ? .on : .off
        settingsMenu.addItem(dynamicRefreshItem)

        dynamicStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dynamicStatusItem.isEnabled = false
        dynamicStatusItem.isHidden = !dynamicRefreshEnabled
        settingsMenu.addItem(dynamicStatusItem)

        let settingsItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Action items
        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let copyItem = NSMenuItem(title: "Copy Usage", action: #selector(copyUsage), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Menu bar text prefix submenu
        let menuBarTextMenu = NSMenu()
        let menuBarTextModes: [(String, String)] = [("Off", "off"), ("Claude", "claude"), ("CC", "cc"), ("Model Name", "model"), ("5 Hour", "5hour")]
        for (title, mode) in menuBarTextModes {
            let item = NSMenuItem(title: title, action: #selector(setMenuBarTextMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = menuBarTextMode == mode ? .on : .off
            menuBarTextModeItems.append(item)
            menuBarTextMenu.addItem(item)
        }
        menuBarTextMenu.addItem(NSMenuItem.separator())
        showWeeklyLabelItem = NSMenuItem(title: "Weekly", action: #selector(toggleWeeklyLabel), keyEquivalent: "")
        showWeeklyLabelItem.target = self
        showWeeklyLabelItem.state = showWeeklyLabel ? .on : .off
        menuBarTextMenu.addItem(showWeeklyLabelItem)
        showSonnetLabelItem = NSMenuItem(title: "Sonnet", action: #selector(toggleSonnetLabel), keyEquivalent: "")
        showSonnetLabelItem.target = self
        showSonnetLabelItem.state = showSonnetLabel ? .on : .off
        menuBarTextMenu.addItem(showSonnetLabelItem)

        menuBarTextItem = NSMenuItem(title: "Display menu bar text", action: nil, keyEquivalent: "")
        menuBarTextItem.submenu = menuBarTextMenu
        menu.addItem(menuBarTextItem)

        // Show Weekly submenu
        let weeklyMenu = NSMenu()
        let weeklyModes: [(String, String)] = [("Off", "off"), ("Low (>30%)", "low"), ("Medium (>60%)", "medium"), ("High (>80%)", "high"), ("Always", "always")]
        for (title, mode) in weeklyModes {
            let item = NSMenuItem(title: title, action: #selector(setWeeklyMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = showWeeklyMode == mode ? .on : .off
            weeklyModeItems.append(item)
            weeklyMenu.addItem(item)
        }
        showWeeklyItem = NSMenuItem(title: "Display weekly usage", action: nil, keyEquivalent: "")
        showWeeklyItem.submenu = weeklyMenu
        menu.addItem(showWeeklyItem)

        // Show Sonnet submenu
        let sonnetDisplayMenu = NSMenu()
        let sonnetModes: [(String, String)] = [("Off", "off"), ("Low (>30%)", "low"), ("Medium (>60%)", "medium"), ("High (>80%)", "high"), ("Always", "always")]
        for (title, mode) in sonnetModes {
            let item = NSMenuItem(title: title, action: #selector(setSonnetMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = showSonnetMode == mode ? .on : .off
            sonnetModeItems.append(item)
            sonnetDisplayMenu.addItem(item)
        }
        showSonnetItem = NSMenuItem(title: "Display sonnet usage", action: nil, keyEquivalent: "")
        showSonnetItem.submenu = sonnetDisplayMenu
        menu.addItem(showSonnetItem)

        // Notifications submenu
        let notificationsMenu = NSMenu()
        resetNotifyItem = NSMenuItem(title: "Reset to 0%", action: #selector(toggleResetNotifications), keyEquivalent: "")
        resetNotifyItem.target = self
        resetNotifyItem.state = resetNotificationsEnabled ? .on : .off
        notificationsMenu.addItem(resetNotifyItem)
        let notificationsItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        notificationsItem.submenu = notificationsMenu
        menu.addItem(notificationsItem)

        if #available(macOS 13.0, *) {
            launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLoginItem.target = self
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(launchAtLoginItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Test values derived from DisplayThresholds so they stay in sync
        let testMenu = NSMenu()

        let errorMenu = NSMenu()
        let testErrors: [(label: String, tag: Int)] = [
            ("Keychain not found", 0),
            ("Keychain parse failure", 1),
            ("Network error", 2),
            ("HTTP 401 (auth)", 3),
            ("HTTP 429 (rate limit)", 4),
            ("HTTP 500 (server)", 5),
            ("HTTP 418 (other)", 6),
            ("Decoding error", 7),
        ]
        for (label, tag) in testErrors {
            let item = NSMenuItem(title: label, action: #selector(testError(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            errorMenu.addItem(item)
        }
        let errorItem = NSMenuItem(title: "Test Errors", action: nil, keyEquivalent: "")
        errorItem.submenu = errorMenu
        testMenu.addItem(errorItem)

        let thresholdMenu = NSMenu()
        let t = DisplayThresholds.self
        let testRanges: [(label: String, pct: Int)] = [
            ("0–\(t.colorGreen - 1)%",  t.colorGreen / 2),
            ("\(t.colorGreen)–\(t.colorYellow - 1)%", (t.colorGreen + t.colorYellow) / 2),
            ("\(t.colorYellow)–\(t.colorOrange - 1)%", (t.colorYellow + t.colorOrange) / 2),
            ("\(t.colorOrange)–\(t.colorRed - 1)%", (t.colorOrange + t.colorRed) / 2),
            ("\(t.colorRed)–100%", (t.colorRed + 100) / 2),
        ]
        for (label, pct) in testRanges {
            let item = NSMenuItem(title: label, action: #selector(testPercentage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            thresholdMenu.addItem(item)
        }
        let thresholdItem = NSMenuItem(title: "Test 5 Hours", action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholdMenu
        testMenu.addItem(thresholdItem)

        let weeklyTestMenu = NSMenu()
        let testWeeklyValues: [(label: String, pct: Int)] = [
            ("Low — 40%", 40),
            ("Medium — 70%", 70),
            ("High — 95%", 95),
            ("Always — 25%", 25),
        ]
        for (label, pct) in testWeeklyValues {
            let item = NSMenuItem(title: label, action: #selector(testWeekly(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            weeklyTestMenu.addItem(item)
        }
        let weeklyTestItem = NSMenuItem(title: "Test Weekly", action: nil, keyEquivalent: "")
        weeklyTestItem.submenu = weeklyTestMenu
        testMenu.addItem(weeklyTestItem)

        let sonnetTestMenu = NSMenu()
        let testSonnetValues: [(label: String, pct: Int)] = [
            ("Low — 40%", 40),
            ("Medium — 70%", 70),
            ("High — 95%", 95),
            ("Always — 25%", 25),
        ]
        for (label, pct) in testSonnetValues {
            let item = NSMenuItem(title: label, action: #selector(testSonnet(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            sonnetTestMenu.addItem(item)
        }
        let sonnetTestItem = NSMenuItem(title: "Test Sonnet", action: nil, keyEquivalent: "")
        sonnetTestItem.submenu = sonnetTestMenu
        testMenu.addItem(sonnetTestItem)

        testMenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearTestDisplay), keyEquivalent: "")
        clearItem.target = self
        testMenu.addItem(clearItem)

        let testItem = NSMenuItem(title: "Test Display", action: nil, keyEquivalent: "")
        testItem.submenu = testMenu
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }
}

// MARK: - Refresh & Timer

extension AppDelegate {
    func updateIntervalMenu() {
        for item in intervalItems {
            item.state = refreshInterval == TimeInterval(item.tag) ? .on : .off
        }
    }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = max(10, effectiveInterval * 0.1)  // 10% tolerance, min 10s
    }

    func adjustDynamicInterval(newPct: Int) {
        guard dynamicRefreshEnabled else { return }
        let ladder = effectiveDynamicLadder
        guard !ladder.isEmpty else { return }

        if let prevPct = dynamicPreviousPct {
            if newPct > prevPct {
                // Usage increasing — step down (faster)
                dynamicTierIndex = max(dynamicTierIndex - 1, 0)
                dynamicUnchangedCount = 0
                dynamicStatusIcon = "↑"
            } else if newPct == prevPct {
                // Unchanged — step up (slower) after 2 consecutive cycles
                dynamicUnchangedCount += 1
                if dynamicUnchangedCount >= 2 {
                    dynamicTierIndex = min(dynamicTierIndex + 1, ladder.count)
                    dynamicUnchangedCount = 0
                }
                // ↓ if still cooling down from a faster tier, ↻ if back at base rate
                if dynamicTierIndex >= ladder.count {
                    dynamicStatusIcon = "↻"
                } else {
                    dynamicStatusIcon = "↓"
                }
            } else {
                // Usage decreased (reset cycle) — reset to idle
                dynamicUnchangedCount = 0
                dynamicStatusIcon = "↻"
            }
            updateMenuBarText()
        }

        dynamicPreviousPct = newPct
        restartTimer()
        updateDynamicStatusItem()
    }

    func updateDynamicStatusItem() {
        guard dynamicRefreshEnabled else {
            dynamicStatusItem.isHidden = true
            return
        }
        let seconds = Int(effectiveInterval)
        let label = seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
        let arrow = (dynamicStatusIcon == "↑" || dynamicStatusIcon == "↓") ? " \(dynamicStatusIcon)" : ""
        dynamicStatusItem.title = "Current: \(label)\(arrow)"
        dynamicStatusItem.isHidden = false
    }

    @objc func toggleDynamicRefresh() {
        dynamicRefreshEnabled.toggle()
        dynamicRefreshItem.state = dynamicRefreshEnabled ? .on : .off

        if dynamicRefreshEnabled {
            let ladder = effectiveDynamicLadder
            dynamicTierIndex = ladder.count  // Start at base rate (user's interval)
            dynamicPreviousPct = fiveHourPct
            dynamicUnchangedCount = 0
            dynamicStatusIcon = "↻"
        } else {
            dynamicPreviousPct = nil
            dynamicUnchangedCount = 0
            dynamicTierIndex = 0
            dynamicStatusIcon = "↻"
        }

        restartTimer()
        updateDynamicStatusItem()
        updateMenuBarText()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        refreshInterval = TimeInterval(sender.tag)
    }

    @objc func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        setMenuBarText("...")

        Task {
            do {
                let token = try await getOAuthToken()
                let usage = try await fetchUsage(token: token)
                let model = readActiveModel()
                await MainActor.run {
                    self.activeModelName = model
                    self.updateUI(usage: usage)
                    self.isRefreshing = false
                }
            } catch let error as UsageError {
                await MainActor.run {
                    self.showError(error)
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.showError(.networkError(error))
                    self.isRefreshing = false
                }
            }
        }
    }

    func updateUI(usage: UsageResponse) {
        for item in errorHintItems { item.isHidden = true }
        errorHintSeparator.isHidden = true

        // 5-hour
        if let h = usage.five_hour {
            let pct = Int(h.utilization)
            if let prev = fiveHourPct, prev > 0, pct == 0 { sendResetNotification(category: "5-hour") }
            fiveHourPct = pct
            fiveHourResetString = h.resets_at
            updateMenuBarText()
            let reset = h.resets_at.map { formatReset($0) } ?? "--"
            fiveHourItem.title = "5-hour: \(pct)% (resets \(reset))"
            fiveHourItem.attributedTitle = tabbedMenuItemString(left: "5-hour: \(pct)%", right: "(resets \(reset))")

            // New reset timestamp means a new usage cycle — clear stale state
            let storedResetAt = UserDefaults.standard.string(forKey: "lastResetAt")
            if let resetAt = h.resets_at, resetAt != storedResetAt {
                UserDefaults.standard.set(resetAt, forKey: "lastResetAt")
                UserDefaults.standard.removeObject(forKey: "usageHistory")
                // Reset dynamic refresh state on new cycle
                dynamicPreviousPct = nil
                dynamicUnchangedCount = 0
                dynamicStatusIcon = "↻"
                let ladder = effectiveDynamicLadder
                dynamicTierIndex = ladder.count
                updateDynamicStatusItem()
            }

            // Save snapshot and update rate
            saveSnapshot(pct: h.utilization)
            if let rateStr = computeRateString() {
                rateItem.title = rateStr
                rateItem.isHidden = false
            } else {
                rateItem.isHidden = true
            }

            // Adjust dynamic refresh interval
            adjustDynamicInterval(newPct: pct)
        } else {
            fiveHourPct = nil
            fiveHourResetString = nil
            setMenuBarText("N/A")
            fiveHourItem.title = "5-hour: N/A"
            fiveHourItem.attributedTitle = nil
            rateItem.isHidden = true
        }

        // Weekly
        if let d = usage.seven_day {
            let weeklyPct = Int(d.utilization)
            if let prev = previousWeeklyPct, prev > 0, weeklyPct == 0 { sendResetNotification(category: "Weekly") }
            previousWeeklyPct = weeklyPct
            cachedWeeklyPct = weeklyPct
            let reset = d.resets_at.map { formatReset($0) } ?? "--"
            weeklyItem.title = "Weekly: \(weeklyPct)% (resets \(reset))"
            weeklyItem.attributedTitle = tabbedMenuItemString(left: "Weekly: \(weeklyPct)%", right: "(resets \(reset))")
        } else {
            cachedWeeklyPct = nil
            weeklyItem.title = "Weekly: --"
            weeklyItem.attributedTitle = nil
        }

        // Sonnet
        if let s = usage.seven_day_sonnet {
            let sonnetPct = Int(s.utilization)
            if let prev = previousSonnetPct, prev > 0, sonnetPct == 0 { sendResetNotification(category: "Sonnet") }
            previousSonnetPct = sonnetPct
            cachedSonnetPct = sonnetPct
            let reset = s.resets_at.map { formatReset($0) } ?? "--"
            sonnetItem.title = "Sonnet: \(sonnetPct)% (resets \(reset))"
            sonnetItem.attributedTitle = tabbedMenuItemString(left: "Sonnet: \(sonnetPct)%", right: "(resets \(reset))")
        } else {
            cachedSonnetPct = nil
            sonnetItem.title = "Sonnet: --"
            sonnetItem.attributedTitle = nil
        }

        // Extra (API returns cents, display as dollars)
        if let e = usage.extra_usage, e.is_enabled,
           let used = e.used_credits, let limit = e.monthly_limit, let util = e.utilization {
            let extraPct = Int(util)
            if let prev = previousExtraPct, prev > 0, extraPct == 0 { sendResetNotification(category: "Extra") }
            previousExtraPct = extraPct
            let leftExtra = String(format: "Extra: $%.2f/$%.0f", used / 100, limit / 100)
            let rightExtra = String(format: "(%.0f%%)", util)
            extraItem.title = "\(leftExtra) \(rightExtra)"
            extraItem.attributedTitle = tabbedMenuItemString(left: leftExtra, right: rightExtra)
        } else {
            extraItem.title = "Extra: --"
            extraItem.attributedTitle = nil
        }

        // Updated time
        lastSuccessfulFetch = Date()
        lastUpdateTime = Date()
        updateRelativeTime()
    }
}

// MARK: - Display

extension AppDelegate {
    func setMenuBarText(_ text: String, color: NSColor? = nil) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if let color = color {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: font
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: font
            ])
        }
        applyMenuBarBorder(color: color)
    }

    func setMenuBarAttributedText(_ attributedString: NSAttributedString, borderColor: NSColor?) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = attributedString
        applyMenuBarBorder(color: borderColor)
    }

    private func applyMenuBarBorder(color: NSColor?) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        if let layer = button.layer {
            let borderColor = color ?? NSColor.labelColor
            layer.borderColor = borderColor.withAlphaComponent(0.5).cgColor
            layer.borderWidth = 1.0
            layer.cornerRadius = 4.0
        }
    }

    func tabbedMenuItemString(left: String, right: String) -> NSAttributedString {
        let menuFont = NSFont.menuFont(ofSize: 0)
        // Tab position just past the widest possible left column
        let maxLeftWidth = ["5-hour: 100%", "Weekly: 100%", "Sonnet: 100%"]
            .map { ($0 as NSString).size(withAttributes: [.font: menuFont]).width }
            .max() ?? 100
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: ceil(maxLeftWidth) + 8)]
        return NSAttributedString(string: "\(left)\t\(right)", attributes: [
            .font: menuFont,
            .paragraphStyle: paragraphStyle
        ])
    }

    func generateMenuBarText(pct: Int, resetString: String?, prefix: String = "", suffix: String = "") -> (text: String, color: NSColor) {
        let color = colorForPercentage(pct)

        if pct < DisplayThresholds.showHoursOnly {
            return ("\(prefix)\(pct)%\(suffix)", color)
        } else if let resetStr = resetString {
            if pct < DisplayThresholds.showFullCountdown {
                let countdown = formatResetHoursOnly(resetStr)
                return ("\(prefix)\(pct)% / \(countdown)\(suffix)", color)
            } else {
                let countdown = formatReset(resetStr)
                return ("\(prefix)\(pct)% / \(countdown)\(suffix)", color)
            }
        } else {
            return ("\(prefix)\(pct)%\(suffix)", color)
        }
    }

    func updateMenuBarText() {
        // One-shot guard: skip one refresh cycle after test display so it stays visible
        if testModeActive {
            testModeActive = false
            return
        }
        guard let pct = fiveHourPct else { return }
        let prefix: String
        switch menuBarTextMode {
        case "claude": prefix = "Claude: "
        case "cc":     prefix = "CC: "
        case "model":  prefix = activeModelName.map { "\($0): " } ?? ""
        case "5hour":  prefix = "5 Hour: "
        default:       prefix = ""
        }
        let showIcon = dynamicRefreshEnabled && (dynamicStatusIcon != "↻" || showDynamicIcon)
        let suffix = showIcon ? " \(dynamicStatusIcon)" : ""
        var (text, color) = generateMenuBarText(pct: pct, resetString: fiveHourResetString, prefix: prefix, suffix: suffix)

        // Determine if weekly should be shown
        var weeklyPctValue: Int?
        if let weeklyPct = cachedWeeklyPct {
            switch showWeeklyMode {
            case "always": weeklyPctValue = weeklyPct
            case "high" where weeklyPct > 80: weeklyPctValue = weeklyPct
            case "medium" where weeklyPct > 60: weeklyPctValue = weeklyPct
            case "low" where weeklyPct > 30: weeklyPctValue = weeklyPct
            default: break
            }
        }

        // Determine if sonnet should be shown
        var sonnetPctValue: Int?
        if let sonnetPct = cachedSonnetPct {
            switch showSonnetMode {
            case "always": sonnetPctValue = sonnetPct
            case "high" where sonnetPct > 80: sonnetPctValue = sonnetPct
            case "medium" where sonnetPct > 60: sonnetPctValue = sonnetPct
            case "low" where sonnetPct > 30: sonnetPctValue = sonnetPct
            default: break
            }
        }

        // Stale data indicator
        var staleText = ""
        if let lastFetch = lastSuccessfulFetch, Date().timeIntervalSince(lastFetch) > refreshInterval * 2 {
            staleText = " (stale)"
        }

        // Build attributed string with per-section colors when extra sections are shown
        if weeklyPctValue != nil || sonnetPctValue != nil {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: font
            ]))
            if let weeklyPct = weeklyPctValue {
                let weeklyColor = colorForPercentage(weeklyPct)
                let weeklyText = showWeeklyLabel ? " | weekly: \(weeklyPct)%" : " | \(weeklyPct)%"
                result.append(NSAttributedString(string: weeklyText, attributes: [
                    .foregroundColor: weeklyColor,
                    .font: font
                ]))
            }
            if let sonnetPct = sonnetPctValue {
                let sonnetColor = colorForPercentage(sonnetPct)
                let sonnetText = showSonnetLabel ? " | sonnet: \(sonnetPct)%" : " | \(sonnetPct)%"
                result.append(NSAttributedString(string: sonnetText, attributes: [
                    .foregroundColor: sonnetColor,
                    .font: font
                ]))
            }
            if !staleText.isEmpty {
                result.append(NSAttributedString(string: staleText, attributes: [
                    .foregroundColor: color,
                    .font: font
                ]))
            }
            setMenuBarAttributedText(result, borderColor: color)
        } else {
            text += staleText
            setMenuBarText(text, color: color)
        }
    }

    func showError(_ error: UsageError) {
        let barText = testModeActive ? "TEST: \(error.menuBarText)" : error.menuBarText
        setMenuBarText(barText, color: error.menuBarColor)

        var lines = [error.description]
        if let hint = error.hint {
            lines += hint.components(separatedBy: "\n")
        }
        for (i, item) in errorHintItems.enumerated() {
            if i < lines.count {
                item.title = lines[i]
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        errorHintSeparator.isHidden = false

        if !testModeActive {
            fiveHourPct = nil
            fiveHourResetString = nil
            cachedWeeklyPct = nil
            cachedSonnetPct = nil
            fiveHourItem.title = "5-hour: --"
            fiveHourItem.attributedTitle = nil
            weeklyItem.title = "Weekly: --"
            weeklyItem.attributedTitle = nil
            sonnetItem.title = "Sonnet: --"
            sonnetItem.attributedTitle = nil
            extraItem.title = "Extra: --"
            extraItem.attributedTitle = nil
            rateItem.isHidden = true

            lastUpdateTime = Date()
            updateRelativeTime()
        }
    }

    func updateRelativeTime() {
        guard let updateTime = lastUpdateTime else { return }
        let elapsed = Int(Date().timeIntervalSince(updateTime))

        if elapsed < 60 {
            updatedItem.title = "Updated just now"
        } else if elapsed < 3600 {
            updatedItem.title = "Updated \(elapsed / 60)m ago"
        } else {
            let h = elapsed / 3600
            let m = (elapsed % 3600) / 60
            updatedItem.title = "Updated \(h)h \(m)m ago"
        }
    }
}

// MARK: - Alerts

extension AppDelegate {
    func sendResetNotification(category: String) {
        guard resetNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Usage Reset"
        content.body = "\(category) usage has reset to 0%"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "reset-\(category)-\(Date().timeIntervalSince1970)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @objc func toggleResetNotifications() {
        resetNotificationsEnabled.toggle()
        resetNotifyItem.state = resetNotificationsEnabled ? .on : .off
    }
}

// MARK: - User Actions

extension AppDelegate {
    func updateHeaderFromCache() {
        if let version = latestKnownVersion, isNewerVersion(remote: version, local: appVersion) {
            headerItem.title = "Update available: \(version)"
            headerItem.action = #selector(openReleasesPage)
            headerItem.target = self
        } else {
            headerItem.title = "Claude Code usage:"
            headerItem.action = nil
            headerItem.target = nil
        }
    }

    @objc func openReleasesPage() {
        if let url = URL(string: "https://github.com/cfranci/claude-usage-swift/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func setMenuBarTextMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String {
            menuBarTextMode = mode
        }
    }

    func updateMenuBarTextModeMenu() {
        for item in menuBarTextModeItems {
            item.state = (item.representedObject as? String) == menuBarTextMode ? .on : .off
        }
    }

    @objc func toggleWeeklyLabel() {
        showWeeklyLabel.toggle()
        showWeeklyLabelItem.state = showWeeklyLabel ? .on : .off
        updateMenuBarText()
    }

    @objc func setWeeklyMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String {
            showWeeklyMode = mode
        }
    }

    func updateWeeklyModeMenu() {
        for item in weeklyModeItems {
            item.state = (item.representedObject as? String) == showWeeklyMode ? .on : .off
        }
    }

    @objc func toggleSonnetLabel() {
        showSonnetLabel.toggle()
        showSonnetLabelItem.state = showSonnetLabel ? .on : .off
        updateMenuBarText()
    }

    @objc func setSonnetMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String {
            showSonnetMode = mode
        }
    }

    func updateSonnetModeMenu() {
        for item in sonnetModeItems {
            item.state = (item.representedObject as? String) == showSonnetMode ? .on : .off
        }
    }

    @objc func openDashboard() {
        if let url = URL(string: "https://console.anthropic.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyUsage() {
        var lines: [String] = []
        lines += [fiveHourItem, weeklyItem, sonnetItem, extraItem]
            .map { $0.title }
        if !rateItem.isHidden {
            lines.append(rateItem.title)
        }
        lines.append(updatedItem.title)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @available(macOS 13.0, *)
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem.state = .on
            }
        } catch {
            NSLog("Launch at login error: \(error)")
        }
    }

    @objc func testPercentage(_ sender: NSMenuItem) {
        testModeActive = true
        let pct = sender.tag

        var resetStr = fiveHourResetString
        if resetStr == nil {
            resetStr = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 37 * 60))
        }

        let (text, color) = generateMenuBarText(pct: pct, resetString: resetStr, prefix: "TEST: ")
        setMenuBarText(text, color: color)
    }

    @objc func testWeekly(_ sender: NSMenuItem) {
        testModeActive = true
        let weeklyPct = sender.tag

        // Use current 5-hour data or a sensible default
        let pct = fiveHourPct ?? 45
        var resetStr = fiveHourResetString
        if resetStr == nil {
            resetStr = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 37 * 60))
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let (text, color) = generateMenuBarText(pct: pct, resetString: resetStr, prefix: "TEST: ")
        let weeklyColor = colorForPercentage(weeklyPct)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: font
        ]))
        let weeklyText = showWeeklyLabel ? " | weekly: \(weeklyPct)%" : " | \(weeklyPct)%"
        result.append(NSAttributedString(string: weeklyText, attributes: [
            .foregroundColor: weeklyColor,
            .font: font
        ]))
        setMenuBarAttributedText(result, borderColor: color)
    }

    @objc func testSonnet(_ sender: NSMenuItem) {
        testModeActive = true
        let sonnetPct = sender.tag

        let pct = fiveHourPct ?? 45
        var resetStr = fiveHourResetString
        if resetStr == nil {
            resetStr = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 37 * 60))
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let (text, color) = generateMenuBarText(pct: pct, resetString: resetStr, prefix: "TEST: ")
        let sonnetColor = colorForPercentage(sonnetPct)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: font
        ]))
        let sonnetText = showSonnetLabel ? " | sonnet: \(sonnetPct)%" : " | \(sonnetPct)%"
        result.append(NSAttributedString(string: sonnetText, attributes: [
            .foregroundColor: sonnetColor,
            .font: font
        ]))
        setMenuBarAttributedText(result, borderColor: color)
    }

    @objc func testError(_ sender: NSMenuItem) {
        testModeActive = true
        let dummyError: Error = NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "simulated error"])
        let error: UsageError
        switch sender.tag {
        case 0: error = .keychainNotFound
        case 1: error = .keychainParseFailure
        case 2: error = .networkError(dummyError)
        case 3: error = .httpError(401)
        case 4: error = .httpError(429)
        case 5: error = .httpError(500)
        case 6: error = .httpError(418)
        case 7: error = .decodingError(dummyError)
        default: return
        }
        showError(error)
    }

    @objc func clearTestDisplay() {
        testModeActive = false
        for item in errorHintItems { item.isHidden = true }
        errorHintSeparator.isHidden = true
        if fiveHourPct != nil {
            updateMenuBarText()
        } else {
            refresh()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
