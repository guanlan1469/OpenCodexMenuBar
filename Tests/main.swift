import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
func account(short: Double?, weekly: Double?, date: Date? = now, seconds: Int = 18000) -> OpenAiAccountItem {
    OpenAiAccountItem(key: "__main__", name: "test", email: nil, plan: nil, isMain: true,
        shortPercent: short, shortRemainingPercent: short.map { 100 - $0 }, shortResetDate: nil,
        shortWindowSeconds: seconds, weeklyPercent: weekly, weeklyRemainingPercent: weekly.map { 100 - $0 },
        weeklyResetDate: nil, resetCredits: 0, updatedAt: date)
}
expect(account(short: 93, weekly: 16).summary(now: now) == "⚡️ 7%", "stricter short window")
expect(account(short: 10, weekly: 98).remainingPercent == 2, "stricter weekly window")
expect(account(short: nil, weekly: nil).summary(now: now) == "⚡️ --", "unknown quota is never 100%")
expect(account(short: 20, weekly: nil).summary(now: now) == "⚡️ ≤80%", "partial quota is an upper bound")
expect(account(short: 20, weekly: 30, date: now.addingTimeInterval(-301)).summary(now: now).hasSuffix("·旧"), "stale cache in menu bar")
expect(account(short: 0, weekly: 0, seconds: 7200).shortLabel == "2小时限制", "actual window duration")
expect(QuotaValue.percent(-8) == 0 && QuotaValue.percent(180) == 100, "clamp quota")
expect(QuotaValue.percent(true) == nil && QuotaValue.percent(Double.nan) == nil, "reject invalid quota")
expect(QuotaValue.status(updatedAt: now, available: true, failed: true, now: now).contains("刷新失败"), "failed refresh is not live")
expect(QuotaValue.isStale(nil, now: now), "unknown timestamp")
let report: [String: Any] = ["reports": [
    ["provider": "google-antigravity", "updatedAt": now.timeIntervalSince1970 * 1000,
     "quota": ["customWindows": [["label": "Gem", "percent": 12], ["label": "Gem (Weekly)", "percent": 30],
                                  ["label": "Cla", "percent": 0], ["label": "Cla (Weekly)", "percent": 8],
                                  ["label": "invalid", "percent": true]]]],
    ["provider": "cursor", "reverseEngineered": true, "quota": ["monthlyPercent": 150, "updatedAt": now.timeIntervalSince1970]]
]]
let parsed = ProviderQuotaParser.parse(data: try JSONSerialization.data(withJSONObject: report))
expect(parsed?.google?.subWindows.count == 4, "ignore invalid provider percent")
expect(Set(parsed!.google!.subWindows.map(\.id)).count == 4, "weekly and short pool identities are distinct")
expect(parsed?.google?.subWindows[1].label == "Gemini 周额度", "recognize weekly pool labels")
expect(parsed?.google?.updatedAt == now && parsed?.cursor?.updatedAt == now, "seconds and milliseconds timestamps")
expect(parsed?.cursor?.subWindows.first?.usedPercent == 100, "monthly fallback clamps quota")
expect(ProviderQuotaParser.parse(data: Data("{}".utf8)) == nil, "reject malformed provider report")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("usage.jsonl")
func record(_ age: Double, _ tokens: Int, provider: String = "openai", model: String = "alias", seconds: Bool = false) -> Data {
    let timestamp = now.addingTimeInterval(-age).timeIntervalSince1970
    var data = try! JSONSerialization.data(withJSONObject: ["timestamp": timestamp * (seconds ? 1 : 1000),
        "model": model, "resolvedModel": "resolved-model", "provider": provider, "totalTokens": tokens], options: [.sortedKeys])
    data.append(10)
    return data
}
func append(_ data: Data) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd(); try file.write(contentsOf: data)
}
var input = record(10, 10) + record(90000, 999) + record(20, 20, provider: "other", seconds: true)
input += Data("malformed\n".utf8)
input += record(-600, 999)
try input.write(to: url)
let reader = UsageLogReader()
var result = reader.load(url: url, now: now)
expect(result.1 == 2 && result.2 == 30, "rolling day, malformed and future records")
expect(result.0.count == 2 && Set(result.0.map(\.id)).count == 2, "same model on different providers")
expect(result.0.allSatisfy { $0.model == "resolved-model" }, "actual resolved model")
_ = reader.load(url: url, now: now)
expect(reader.bytesRead == 0, "unchanged logs do not reparse")
let next = record(5, 7)
try append(next.prefix(next.count / 2))
result = reader.load(url: url, now: now)
expect(result.1 == 2, "partial line held")
try append(next.suffix(next.count - next.count / 2))
result = reader.load(url: url, now: now)
expect(result.1 == 3 && result.2 == 37, "completed line counted exactly once")
result = reader.load(url: url, now: now.addingTimeInterval(86401))
expect(result.1 == 0 && reader.bytesRead == 0, "records expire without file writes")
try record(1, 42).write(to: url)
result = reader.load(url: url, now: now)
expect(result.1 == 1 && result.2 == 42, "truncated file resets totals")
try record(1, 55).write(to: url, options: .atomic)
result = reader.load(url: url, now: now)
expect(result.1 == 1 && result.2 == 55, "rotated file replaces prior totals")
let file = try FileHandle(forWritingTo: url)
try file.truncate(atOffset: 0)
try file.write(contentsOf: record(1, 63) + record(2, 64))
try file.close()
result = reader.load(url: url, now: now)
expect(result.1 == 2 && result.2 == 127, "truncate and regrow on same inode")
try FileManager.default.removeItem(at: url)
result = reader.load(url: url, now: now)
expect(!reader.isAvailable && result.1 == 0, "missing logs distinguished from no activity")
try record(1, 12).write(to: url)
expect(reader.load(url: url, now: now).2 == 12 && reader.isAvailable, "log recovery")
let large = try QuotaCommand.run(executable: "/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero"], timeout: 3)
expect(large.count == 262144, "large stdout does not deadlock")
do {
    _ = try QuotaCommand.run(executable: "/bin/sh", arguments: ["-c", "exit 7"])
    expect(false, "nonzero exit must fail")
} catch QuotaCommand.Failure.exitStatus(let code) { expect(code == 7, "preserve exit status") }
let start = Date()
do {
    _ = try QuotaCommand.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    expect(false, "timeout must fail")
} catch QuotaCommand.Failure.timedOut { expect(Date().timeIntervalSince(start) < 3, "hard deadline for TERM-resistant process") }
print("PASS: \(checks) regression checks")

if CommandLine.arguments.count > 1 {
    let live = URL(fileURLWithPath: CommandLine.arguments[1])
    let reader = UsageLogReader()
    let start = Date()
    let first = reader.load(url: live)
    let cold = Date().timeIntervalSince(start)
    let bytes = reader.bytesRead
    let warmStart = Date()
    let second = reader.load(url: live)
    let warm = Date().timeIntervalSince(warmStart)
    print(String(format: "Live log: %d bytes; cold %.4fs; warm %.4fs; warm bytes %d; calls %d; tokens %d", bytes, cold, warm, reader.bytesRead, second.1, second.2))
    expect(reader.isAvailable && first.1 > 0, "live usage readable")
}
