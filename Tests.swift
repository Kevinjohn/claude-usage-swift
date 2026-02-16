// Tests.swift — Standalone unit tests for pure functions in ClaudeUsage.swift
// Compile and run: swiftc -O -o Tests Tests.swift && ./Tests
// No framework dependencies required.
//
// IMPORTANT: Functions below are COPIES of the real implementations in
// ClaudeUsage.swift. If you change any of these functions in the source,
// you MUST update the copies here too. Search for "SYNC CHECK" to find
// each copied function.

import Foundation

// ============================================================================
// MARK: - Copy of functions under test (pure functions extracted from source)
// ============================================================================

// SYNC CHECK: Must match isNewerVersion() in ClaudeUsage.swift

func isNewerVersion(remote: String, local: String) -> Bool {
    func normalize(_ v: String) -> [Int] {
        let stripped = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let base = stripped.split(separator: "-").first.map(String.init) ?? stripped
        return base.split(separator: ".").compactMap { Int($0) }
    }
    func hasPreRelease(_ v: String) -> Bool {
        let stripped = v.hasPrefix("v") ? String(v.dropFirst()) : v
        return stripped.contains("-")
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
    return hasPreRelease(local) && !hasPreRelease(remote)
}

// SYNC CHECK: Must match DisplayThresholds and colorForPercentage() in ClaudeUsage.swift

enum DisplayThresholds {
    static let colorGreen  = 30
    static let colorYellow = 61
    static let colorOrange = 81
    static let colorRed    = 91
}

func colorNameForPercentage(_ pct: Int) -> String {
    switch pct {
    case ..<DisplayThresholds.colorGreen:  return "grey"
    case ..<DisplayThresholds.colorYellow: return "green"
    case ..<DisplayThresholds.colorOrange: return "yellow"
    case ..<DisplayThresholds.colorRed:    return "orange"
    default:                               return "red"
    }
}

// -- clamp helper (mirrors min(100, max(0, Int(value)))) --

func clampPct(_ value: Double) -> Int {
    min(100, max(0, Int(value)))
}

// ============================================================================
// MARK: - Test harness
// ============================================================================

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n  \(name)")
}

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
        print("    ✓ \(message)")
    } else {
        failed += 1
        print("    ✗ FAIL: \(message) (line \(line))")
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
        print("    ✓ \(message)")
    } else {
        failed += 1
        print("    ✗ FAIL: \(message) — expected \(expected), got \(actual) (line \(line))")
    }
}

// ============================================================================
// MARK: - Tests
// ============================================================================

print("Running tests...\n")

// ---------------------------------------------------------------------------
// isNewerVersion
// ---------------------------------------------------------------------------

group("isNewerVersion — basic comparisons")
assert(isNewerVersion(remote: "2.9.0", local: "2.8.1") == true,
       "2.9.0 > 2.8.1")
assert(isNewerVersion(remote: "2.8.2", local: "2.8.1") == true,
       "2.8.2 > 2.8.1")
assert(isNewerVersion(remote: "3.0.0", local: "2.8.1") == true,
       "3.0.0 > 2.8.1")
assert(isNewerVersion(remote: "2.8.1", local: "2.8.1") == false,
       "2.8.1 == 2.8.1")
assert(isNewerVersion(remote: "2.8.0", local: "2.8.1") == false,
       "2.8.0 < 2.8.1")
assert(isNewerVersion(remote: "1.0.0", local: "2.8.1") == false,
       "1.0.0 < 2.8.1")

group("isNewerVersion — v prefix")
assert(isNewerVersion(remote: "v2.9.0", local: "2.8.1") == true,
       "v2.9.0 > 2.8.1")
assert(isNewerVersion(remote: "2.9.0", local: "v2.8.1") == true,
       "2.9.0 > v2.8.1")
assert(isNewerVersion(remote: "v2.8.1", local: "v2.8.1") == false,
       "v2.8.1 == v2.8.1")
assert(isNewerVersion(remote: "v2.8.0", local: "v2.9.0") == false,
       "v2.8.0 < v2.9.0")

group("isNewerVersion — pre-release handling (new behavior)")
assert(isNewerVersion(remote: "2.8.1", local: "2.8.1-beta") == true,
       "clean 2.8.1 is newer than 2.8.1-beta")
assert(isNewerVersion(remote: "2.8.1-beta", local: "2.8.1") == false,
       "2.8.1-beta is NOT newer than clean 2.8.1")
assert(isNewerVersion(remote: "2.8.1-beta", local: "2.8.1-beta") == false,
       "2.8.1-beta == 2.8.1-beta (both pre-release)")
assert(isNewerVersion(remote: "2.8.1-rc.1", local: "2.8.1-beta") == false,
       "2.8.1-rc.1 vs 2.8.1-beta: same numeric, both pre-release → false")
assert(isNewerVersion(remote: "v2.8.1", local: "v2.8.1-beta") == true,
       "v2.8.1 (clean) > v2.8.1-beta (with v prefix)")
assert(isNewerVersion(remote: "v2.8.1-beta", local: "v2.8.1") == false,
       "v2.8.1-beta NOT newer than v2.8.1 (with v prefix)")

group("isNewerVersion — pre-release with higher numeric version")
assert(isNewerVersion(remote: "2.9.0-beta", local: "2.8.1") == true,
       "2.9.0-beta > 2.8.1 (numeric wins over pre-release)")
assert(isNewerVersion(remote: "2.8.0-beta", local: "2.8.1") == false,
       "2.8.0-beta < 2.8.1 (numeric still lower)")
assert(isNewerVersion(remote: "2.8.2", local: "2.8.1-beta") == true,
       "2.8.2 > 2.8.1-beta (numeric wins)")

group("isNewerVersion — zero-padding for unequal lengths")
assert(isNewerVersion(remote: "2.8", local: "2.8.0") == false,
       "2.8 == 2.8.0 (zero-padded)")
assert(isNewerVersion(remote: "2.8.0", local: "2.8") == false,
       "2.8.0 == 2.8 (zero-padded)")
assert(isNewerVersion(remote: "2.8.1", local: "2.8") == true,
       "2.8.1 > 2.8 (2.8.1 > 2.8.0)")
assert(isNewerVersion(remote: "2", local: "2.0.0") == false,
       "2 == 2.0.0")

group("isNewerVersion — edge cases")
assert(isNewerVersion(remote: "", local: "") == false,
       "empty == empty")
assert(isNewerVersion(remote: "1.0.0", local: "") == true,
       "1.0.0 > empty")
assert(isNewerVersion(remote: "", local: "1.0.0") == false,
       "empty < 1.0.0")
assert(isNewerVersion(remote: "0.0.1", local: "0.0.0") == true,
       "0.0.1 > 0.0.0")
assert(isNewerVersion(remote: "v", local: "v") == false,
       "bare v == bare v (both normalize to [])")
assert(isNewerVersion(remote: "abc", local: "def") == false,
       "non-numeric strings both normalize to []")

group("isNewerVersion — symmetry (every true has a false reverse)")
assert(isNewerVersion(remote: "2.8.1", local: "2.9.0") == false,
       "2.8.1 < 2.9.0 (reverse of 2.9.0 > 2.8.1)")
assert(isNewerVersion(remote: "2.8.1", local: "2.8.2") == false,
       "2.8.1 < 2.8.2 (reverse of 2.8.2 > 2.8.1)")
assert(isNewerVersion(remote: "2.8.1", local: "3.0.0") == false,
       "2.8.1 < 3.0.0 (reverse of 3.0.0 > 2.8.1)")
assert(isNewerVersion(remote: "2.8.1", local: "2.9.0-beta") == false,
       "2.8.1 < 2.9.0-beta (reverse of 2.9.0-beta > 2.8.1)")
assert(isNewerVersion(remote: "2.8.1-beta", local: "2.8.2") == false,
       "2.8.1-beta < 2.8.2 (reverse of 2.8.2 > 2.8.1-beta)")

group("isNewerVersion — complex pre-release suffixes")
assert(isNewerVersion(remote: "2.8.1", local: "2.8.1-beta.2") == true,
       "clean > 2.8.1-beta.2 (suffix contains '-')")
assert(isNewerVersion(remote: "2.8.1-alpha", local: "2.8.1-beta") == false,
       "both pre-release, same numeric → false")
assert(isNewerVersion(remote: "2.8.1-1", local: "2.8.1") == false,
       "2.8.1-1 (pre-release) NOT newer than clean 2.8.1")
assert(isNewerVersion(remote: "1.0.0-", local: "1.0.0") == false,
       "1.0.0- (trailing dash) NOT newer than clean 1.0.0")
assert(isNewerVersion(remote: "1.0.0", local: "1.0.0-") == true,
       "clean 1.0.0 > 1.0.0- (trailing dash is pre-release)")

// ---------------------------------------------------------------------------
// colorNameForPercentage (mirrors colorForPercentage)
// ---------------------------------------------------------------------------

group("colorForPercentage — boundary values")
assertEqual(colorNameForPercentage(0), "grey", "0% → grey")
assertEqual(colorNameForPercentage(29), "grey", "29% → grey")
assertEqual(colorNameForPercentage(30), "green", "30% → green (boundary)")
assertEqual(colorNameForPercentage(60), "green", "60% → green")
assertEqual(colorNameForPercentage(61), "yellow", "61% → yellow (boundary)")
assertEqual(colorNameForPercentage(80), "yellow", "80% → yellow")
assertEqual(colorNameForPercentage(81), "orange", "81% → orange (boundary)")
assertEqual(colorNameForPercentage(90), "orange", "90% → orange")
assertEqual(colorNameForPercentage(91), "red", "91% → red (boundary)")
assertEqual(colorNameForPercentage(100), "red", "100% → red")

group("colorForPercentage — out-of-range (clamped inputs)")
assertEqual(colorNameForPercentage(-1), "grey", "-1 → grey (negative)")
assertEqual(colorNameForPercentage(-100), "grey", "-100 → grey (very negative)")
assertEqual(colorNameForPercentage(101), "red", "101 → red (over 100)")
assertEqual(colorNameForPercentage(200), "red", "200 → red (way over)")

// ---------------------------------------------------------------------------
// clampPct (mirrors min(100, max(0, Int(value))))
// ---------------------------------------------------------------------------

group("clampPct — normal values")
assertEqual(clampPct(0.0), 0, "0.0 → 0")
assertEqual(clampPct(50.0), 50, "50.0 → 50")
assertEqual(clampPct(100.0), 100, "100.0 → 100")
assertEqual(clampPct(75.7), 75, "75.7 → 75 (truncates)")
assertEqual(clampPct(99.9), 99, "99.9 → 99 (truncates, doesn't round)")

group("clampPct — boundary clamping")
assertEqual(clampPct(-1.0), 0, "-1.0 → 0 (clamped)")
assertEqual(clampPct(-50.5), 0, "-50.5 → 0 (clamped)")
assertEqual(clampPct(101.0), 100, "101.0 → 100 (clamped)")
assertEqual(clampPct(200.0), 100, "200.0 → 100 (clamped)")
assertEqual(clampPct(100.1), 100, "100.1 → 100 (clamped)")
assertEqual(clampPct(-0.1), 0, "-0.1 → 0 (negative truncates to 0)")

// NOTE: clampPct with infinity/NaN is skipped — Int(Double.infinity) and
// Int(Double.nan) are undefined behavior in Swift. The API returns finite
// doubles so this isn't a real-world concern.

// ============================================================================
// MARK: - Results
// ============================================================================

print("\n" + String(repeating: "=", count: 60))
if failed == 0 {
    print("All \(passed) tests passed!")
} else {
    print("\(passed) passed, \(failed) FAILED")
}
print(String(repeating: "=", count: 60))

exit(failed > 0 ? 1 : 0)
