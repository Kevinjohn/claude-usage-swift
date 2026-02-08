import Cocoa

// MARK: - Usage API

struct UsageResponse: Codable {
    let five_hour: UsageLimit?
    let seven_day: UsageLimit?
    let seven_day_sonnet: UsageLimit?
    let extra_usage: ExtraUsage?
}

struct UsageLimit: Codable {
    let utilization: Double
    let resets_at: String
}

struct ExtraUsage: Codable {
    let is_enabled: Bool
    let monthly_limit: Double
    let used_credits: Double
    let utilization: Double
}

func getOAuthToken() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let jsonData = json.data(using: .utf8),
              let creds = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = creds["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    } catch {
        return nil
    }
}

func fetchUsage(token: String, completion: @escaping (UsageResponse?) -> Void) {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        completion(nil)
        return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-code/2.0.31", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data = data,
              let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            completion(nil)
            return
        }
        completion(usage)
    }.resume()
}

func formatReset(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    guard let date = formatter.date(from: isoString) else {
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: isoString) else { return "?" }
        return formatResetDate(date)
    }
    return formatResetDate(date)
}

func formatResetDate(_ date: Date) -> String {
    let diff = date.timeIntervalSince(Date())
    if diff < 0 { return "now" }

    let hours = Int(diff) / 3600
    let mins = (Int(diff) % 3600) / 60

    if hours == 0 {
        return "\(mins)m"
    } else if hours < 24 {
        return "\(hours)h \(mins)m"
    } else {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var timer: Timer?

    // Menu items
    var fiveHourItem: NSMenuItem!
    var weeklyItem: NSMenuItem!
    var sonnetItem: NSMenuItem!
    var extraItem: NSMenuItem!
    var updatedItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "..."

        // Create menu
        menu = NSMenu()

        fiveHourItem = NSMenuItem(title: "5-hour: ...", action: nil, keyEquivalent: "")
        weeklyItem = NSMenuItem(title: "Weekly: ...", action: nil, keyEquivalent: "")
        sonnetItem = NSMenuItem(title: "Sonnet: ...", action: nil, keyEquivalent: "")
        extraItem = NSMenuItem(title: "Extra: ...", action: nil, keyEquivalent: "")
        updatedItem = NSMenuItem(title: "Updated: --", action: nil, keyEquivalent: "")

        menu.addItem(fiveHourItem)
        menu.addItem(weeklyItem)
        menu.addItem(sonnetItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(extraItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Initial fetch
        refresh()

        // Auto-refresh every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        DispatchQueue.main.async {
            self.statusItem.button?.title = "..."
        }

        guard let token = getOAuthToken() else {
            DispatchQueue.main.async {
                self.statusItem.button?.title = "?"
            }
            return
        }

        fetchUsage(token: token) { [weak self] usage in
            DispatchQueue.main.async {
                self?.updateUI(usage: usage)
            }
        }
    }

    func updateUI(usage: UsageResponse?) {
        guard let usage = usage else {
            statusItem.button?.title = "?"
            return
        }

        // 5-hour
        if let h = usage.five_hour {
            let pct = Int(h.utilization)
            statusItem.button?.title = "\(pct)%"
            fiveHourItem.title = "5-hour: \(pct)% (resets \(formatReset(h.resets_at)))"
        }

        // Weekly
        if let d = usage.seven_day {
            weeklyItem.title = "Weekly: \(Int(d.utilization))% (resets \(formatReset(d.resets_at)))"
        }

        // Sonnet
        if let s = usage.seven_day_sonnet {
            sonnetItem.title = "Sonnet: \(Int(s.utilization))% (resets \(formatReset(s.resets_at)))"
        } else {
            sonnetItem.title = "Sonnet: --"
        }

        // Extra
        if let e = usage.extra_usage, e.is_enabled {
            let used = e.used_credits / 100
            let limit = e.monthly_limit / 100
            extraItem.title = String(format: "Extra: $%.2f/$%.0f (%.0f%%)", used, limit, e.utilization)
        } else {
            extraItem.title = "Extra: --"
        }

        // Updated time
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        updatedItem.title = "Updated: \(df.string(from: Date()))"
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
