import Cocoa
import ServiceManagement
import UserNotifications

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
/// Adjust these values to change when colors, countdown detail, and alerts trigger.
struct DisplayThresholds {
    // Color thresholds (menu bar text color changes at these boundaries)
    static let colorGreen  = 30   // below this: grey, at/above: green
    static let colorYellow = 61   // at/above: yellow
    static let colorOrange = 81   // at/above: orange
    static let colorRed    = 91   // at/above: red

    // Menu bar countdown detail thresholds
    static let showHoursOnly    = 30  // at/above: show hours-only countdown
    static let showFullCountdown = 61  // at/above: show full h:m countdown

    // Notification alert thresholds (fires once per reset cycle)
    static let alertThresholds: [Int] = [80, 90]
}

// MARK: - Usage Snapshot

struct UsageSnapshot: Codable {
    let timestamp: TimeInterval
    let pct: Double
}

// MARK: - Ephemeral URLSession

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
        case .networkError: return "net?"
        case .httpError(let code) where code == 401 || code == 403: return "auth?"
        case .httpError: return "http?"
        case .decodingError: return "json?"
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
        case .httpError(let code):
            return "HTTP \(code) from Anthropic API"
        case .decodingError(let error):
            return "Could not decode API response: \(error.localizedDescription)"
        }
    }
}

// MARK: - Shared Date Parser

func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

// MARK: - Networking (async)

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
    request.setValue("ClaudeUsage-menubar/2.1.1", forHTTPHeaderField: "User-Agent")

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
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
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
    guard snapshots.count >= 2 else { return nil }

    let first = snapshots.first!
    let last = snapshots.last!
    let elapsed = last.timestamp - first.timestamp
    guard elapsed >= 300 else { return nil } // Need 5+ minutes

    let pctDelta = last.pct - first.pct
    let hoursElapsed = elapsed / 3600
    let ratePerHour = pctDelta / hoursElapsed

    if ratePerHour <= 0 {
        return "Usage stable"
    }

    let remaining = 100.0 - last.pct
    let hoursToLimit = remaining / ratePerHour

    guard hoursToLimit < 100 else {
        return String(format: "~%.0f%%/hr", ratePerHour)
    }

    let hrs = Int(hoursToLimit)
    return String(format: "~%.0f%%/hr — limit in ~%dh at this pace", ratePerHour, hrs)
}

// MARK: - Model Detection

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
    var modelItem: NSMenuItem!
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

    // Show Model in Menu Bar
    var showModelItem: NSMenuItem!
    var showModelInMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: "showModelInMenuBar") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showModelInMenuBar") }
    }

    // Usage Alerts
    var alertsItem: NSMenuItem!
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }
    var alertedThresholds: Set<Int> = []

    // Stale data tracking
    var lastSuccessfulFetch: Date?
    var lastUpdateTime: Date?

    // Current interval in seconds
    var refreshInterval: TimeInterval = 900 {
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

        // Create menu
        menu = NSMenu()

        modelItem = NSMenuItem(title: "Model: --", action: nil, keyEquivalent: "")
        fiveHourItem = NSMenuItem(title: "5-hour: ...", action: nil, keyEquivalent: "")
        weeklyItem = NSMenuItem(title: "Weekly: ...", action: nil, keyEquivalent: "")
        sonnetItem = NSMenuItem(title: "Sonnet: ...", action: nil, keyEquivalent: "")
        extraItem = NSMenuItem(title: "Extra: ...", action: nil, keyEquivalent: "")
        rateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        rateItem.isHidden = true
        updatedItem = NSMenuItem(title: "Updated: --", action: nil, keyEquivalent: "")

        menu.addItem(modelItem)
        menu.addItem(fiveHourItem)
        menu.addItem(rateItem)
        menu.addItem(weeklyItem)
        menu.addItem(sonnetItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(extraItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        // Action items
        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let copyItem = NSMenuItem(title: "Copy Usage", action: #selector(copyUsage), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
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

        let settingsItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        // Usage Alerts toggle
        alertsItem = NSMenuItem(title: "Usage Alerts", action: #selector(toggleAlerts), keyEquivalent: "")
        alertsItem.target = self
        alertsItem.state = notificationsEnabled ? .on : .off
        menu.addItem(alertsItem)

        // Show Model toggle
        showModelItem = NSMenuItem(title: "Display model name", action: #selector(toggleShowModel), keyEquivalent: "")
        showModelItem.target = self
        showModelItem.state = showModelInMenuBar ? .on : .off
        menu.addItem(showModelItem)

        if #available(macOS 13.0, *) {
            launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLoginItem.target = self
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(launchAtLoginItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Test display submenu — derived from DisplayThresholds
        let testMenu = NSMenu()
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
            testMenu.addItem(item)
        }
        testMenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearTestDisplay), keyEquivalent: "")
        clearItem.target = self
        testMenu.addItem(clearItem)

        let testItem = NSMenuItem(title: "Test Display", action: nil, keyEquivalent: "")
        testItem.submenu = testMenu
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Restore saved refresh interval
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        if stored > 0 { refreshInterval = stored }

        // Update checkmarks
        updateIntervalMenu()

        // Request notification authorization
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Initial fetch
        refresh()

        // Start timer
        restartTimer()

        // Update menu bar countdown and relative time every 60s (display only, no API calls)
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateMenuBarText()
            self?.updateRelativeTime()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        displayTimer?.invalidate()
    }

    func updateIntervalMenu() {
        for item in intervalItems {
            item.state = refreshInterval == TimeInterval(item.tag) ? .on : .off
        }
    }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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

    func setMenuBarText(_ text: String, color: NSColor? = nil) {
        guard let button = statusItem.button else { return }
        if let color = color {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: font
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: text)
        }
    }

    func generateMenuBarText(pct: Int, resetString: String?, prefix: String = "") -> (text: String, color: NSColor) {
        let color = colorForPercentage(pct)

        if pct < DisplayThresholds.showHoursOnly {
            return ("\(prefix)\(pct)%", color)
        } else if let resetStr = resetString {
            if pct < DisplayThresholds.showFullCountdown {
                let countdown = formatResetHoursOnly(resetStr)
                return ("\(prefix)\(pct)% / \(countdown)", color)
            } else {
                let countdown = formatReset(resetStr)
                return ("\(prefix)\(pct)% / \(countdown)", color)
            }
        } else {
            return ("\(prefix)\(pct)%", color)
        }
    }

    func updateMenuBarText() {
        if testModeActive {
            testModeActive = false
            return
        }
        guard let pct = fiveHourPct else { return }
        let prefix = (showModelInMenuBar ? activeModelName.map { "\($0): " } : nil) ?? ""
        var (text, color) = generateMenuBarText(pct: pct, resetString: fiveHourResetString, prefix: prefix)

        // Stale data indicator
        if let lastFetch = lastSuccessfulFetch, Date().timeIntervalSince(lastFetch) > refreshInterval * 2 {
            text += " (stale)"
        }

        setMenuBarText(text, color: color)
    }

    func showError(_ error: UsageError) {
        fiveHourPct = nil
        fiveHourResetString = nil
        setMenuBarText(error.menuBarText)
        fiveHourItem.title = "5-hour: \(error.description)"
        weeklyItem.title = "Weekly: --"
        sonnetItem.title = "Sonnet: --"
        extraItem.title = "Extra: --"
        rateItem.isHidden = true

        lastUpdateTime = Date()
        updateRelativeTime()
    }

    func updateUI(usage: UsageResponse) {
        // Model
        if let model = activeModelName {
            modelItem.title = "Model: \(model)"
            modelItem.isHidden = false
        } else {
            modelItem.isHidden = true
        }

        // 5-hour
        if let h = usage.five_hour {
            let pct = Int(h.utilization)
            fiveHourPct = pct
            fiveHourResetString = h.resets_at
            updateMenuBarText()
            let reset = h.resets_at.map { formatReset($0) } ?? "--"
            fiveHourItem.title = "5-hour: \(pct)% (resets \(reset))"

            // Detect reset cycle change
            let storedResetAt = UserDefaults.standard.string(forKey: "lastResetAt")
            if let resetAt = h.resets_at, resetAt != storedResetAt {
                UserDefaults.standard.set(resetAt, forKey: "lastResetAt")
                alertedThresholds.removeAll()
                UserDefaults.standard.removeObject(forKey: "usageHistory")
            }

            // Save snapshot and update rate
            saveSnapshot(pct: h.utilization)
            if let rateStr = computeRateString() {
                rateItem.title = rateStr
                rateItem.isHidden = false
            } else {
                rateItem.isHidden = true
            }

            // Check thresholds
            checkThresholds(pct: pct)
        } else {
            fiveHourPct = nil
            fiveHourResetString = nil
            setMenuBarText("N/A")
            fiveHourItem.title = "5-hour: N/A"
            rateItem.isHidden = true
        }

        // Weekly
        if let d = usage.seven_day {
            let reset = d.resets_at.map { formatReset($0) } ?? "--"
            weeklyItem.title = "Weekly: \(Int(d.utilization))% (resets \(reset))"
        }

        // Sonnet
        if let s = usage.seven_day_sonnet {
            let reset = s.resets_at.map { formatReset($0) } ?? "--"
            sonnetItem.title = "Sonnet: \(Int(s.utilization))% (resets \(reset))"
        } else {
            sonnetItem.title = "Sonnet: --"
        }

        // Extra
        if let e = usage.extra_usage, e.is_enabled,
           let used = e.used_credits, let limit = e.monthly_limit, let util = e.utilization {
            extraItem.title = String(format: "Extra: $%.2f/$%.0f (%.0f%%)", used / 100, limit / 100, util)
        } else {
            extraItem.title = "Extra: --"
        }

        // Updated time
        lastSuccessfulFetch = Date()
        lastUpdateTime = Date()
        updateRelativeTime()
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

    // MARK: - Threshold Alerts

    func checkThresholds(pct: Int) {
        guard notificationsEnabled else { return }

        for threshold in DisplayThresholds.alertThresholds {
            if pct >= threshold && !alertedThresholds.contains(threshold) {
                alertedThresholds.insert(threshold)
                sendThresholdNotification(pct: pct, threshold: threshold)
            }
        }
    }

    func sendThresholdNotification(pct: Int, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Alert"
        content.body = "Usage has reached \(pct)% (threshold: \(threshold)%)"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "threshold-\(threshold)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @objc func toggleAlerts() {
        notificationsEnabled.toggle()
        alertsItem.state = notificationsEnabled ? .on : .off
    }

    @objc func toggleShowModel() {
        showModelInMenuBar.toggle()
        showModelItem.state = showModelInMenuBar ? .on : .off
        updateMenuBarText()
    }

    @objc func openDashboard() {
        if let url = URL(string: "https://console.anthropic.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyUsage() {
        var lines: [String] = []
        if !modelItem.isHidden { lines.append(modelItem.title) }
        lines += [fiveHourItem, weeklyItem, sonnetItem, extraItem]
            .compactMap { $0?.title }
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

    @objc func clearTestDisplay() {
        testModeActive = false
        updateMenuBarText()
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
