import Foundation
import CoreFoundation
import Darwin

// MARK: - Models

struct OpenAiAccountItem: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let email: String?
    let plan: String?
    let isMain: Bool
    let shortPercent: Double?
    let shortRemainingPercent: Double?
    let shortResetDate: Date?
    let shortWindowSeconds: Int?
    let weeklyPercent: Double?
    let weeklyRemainingPercent: Double?
    let weeklyResetDate: Date?
    let resetCredits: Int

    let updatedAt: Date?

    var usedPercent: Double? { [shortPercent, weeklyPercent].compactMap { $0 }.max() }
    var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
    var isComplete: Bool { shortPercent != nil && weeklyPercent != nil }
    var shortLabel: String {
        guard let seconds = shortWindowSeconds, seconds > 0 else { return "短周期限制" }
        return seconds % 3600 == 0 ? "\(seconds / 3600)小时限制" : "\(seconds / 60)分钟限制"
    }
    func summary(now: Date = Date()) -> String {
        guard let remainingPercent else { return "⚡️ --" }
        let prefix = isComplete ? "" : "≤"
        let stale = QuotaValue.isStale(updatedAt, now: now) ? " ·旧" : ""
        return "⚡️ \(prefix)\(Int(remainingPercent.rounded()))%\(stale)"
    }

}

struct SubQuotaWindow: Identifiable {
    var id: String { label }
    let label: String
    let hint: String?
    let usedPercent: Double
    let remainingPercent: Double
    let resetDate: Date?
}

struct CursorQuotaSnapshot {
    let subWindows: [SubQuotaWindow]
    let monthlyUsedPercent: Double?
    let resetDate: Date?
    let updatedAt: Date?
    let experimental: Bool
}

struct GoogleQuotaSnapshot {
    let subWindows: [SubQuotaWindow]
    let resetDate: Date?
    let updatedAt: Date?
}

struct ProviderQuotaSnapshots {
    let google: GoogleQuotaSnapshot?
    let cursor: CursorQuotaSnapshot?
}

struct ProviderSectionData {
    let openAiAccounts: [OpenAiAccountItem]
    let googleSubWindows: [SubQuotaWindow]
    let googleEmail: String
    let googleDisabled: Bool
    let googleResetText: String
    let googleQuotaStatusText: String
    let googleCalls24h: Int
    let googleTokens24h: Int
    
    let cursorSubWindows: [SubQuotaWindow]
    let cursorUser: String
    let cursorDisabled: Bool
    let cursorResetDate: Date?
    let cursorResetText: String
    let cursorQuotaStatusText: String
    let cursorQuotaExperimental: Bool
    let cursorCalls24h: Int
    let cursorTokens24h: Int
}

struct ModelUsageStat: Identifiable {
    var id: String { provider + "\u{0}" + model }
    let model: String
    let provider: String
    let calls: Int
    let tokens: Int
    let lastSeen: Date
}

enum QuotaValue {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func percent(_ value: Any?) -> Double? {
        number(value).map { min(100, max(0, $0)) }
    }

    static func isStale(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) > 300 || date.timeIntervalSince(now) > 60
    }

    static func status(updatedAt: Date?, available: Bool, failed: Bool, now: Date = Date()) -> String {
        guard available else { return "额度暂不可用" }
        let state = failed ? "刷新失败 · 保留缓存" : (isStale(updatedAt, now: now) ? "缓存待更新" : "已更新")
        guard let updatedAt else { return state + " · 时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(updatedAt, inSameDayAs: now) ? "HH:mm:ss" : "M-d HH:mm"
        return state + " · " + formatter.string(from: updatedAt)
    }
}

/// File-backed stdout avoids the full-pipe deadlock caused by waiting before reading.
enum QuotaCommand {
    enum Failure: Error { case timedOut, exitStatus(Int32), outputTooLarge }

    static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 15) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencodex-quota-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            throw Failure.timedOut
        }
        guard process.terminationStatus == 0 else { throw Failure.exitStatus(process.terminationStatus) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 8 * 1024 * 1024 else { throw Failure.outputTooLarge }
        return try Data(contentsOf: url)
    }
}

/// Reads only newly appended bytes. Keeps complete records within the rolling day;
/// an unfinished final JSON line is held until its newline arrives.
final class UsageLogReader {
    private struct Entry {
        let timestamp: Date
        let model: String
        let provider: String
        let tokens: Int
    }
    private var entries: [Entry] = []
    private var fileID: String?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var checkpoint = Data()
    private(set) var isAvailable = true
    private(set) var bytesRead = 0

    private func reset() {
        entries.removeAll(keepingCapacity: true)
        offset = 0
        pending.removeAll(keepingCapacity: true)
        checkpoint.removeAll(keepingCapacity: true)
    }

    func load(url: URL, now: Date = Date()) -> ([ModelUsageStat], Int, Int, [String: (calls: Int, tokens: Int)]) {
        bytesRead = 0
        let cutoff = now.addingTimeInterval(-86400)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            let identity = "\(info.st_dev):\(info.st_ino)"
            let size = UInt64(max(0, info.st_size))
            if fileID != identity || size < offset { reset() }
            fileID = identity
            // Detect a truncate-and-regrow between polls, even with an unchanged inode.
            if !checkpoint.isEmpty {
                try handle.seek(toOffset: offset - UInt64(checkpoint.count))
                if try handle.read(upToCount: checkpoint.count) != checkpoint { reset() }
            }
            try handle.seek(toOffset: offset)
            while offset < size {
                guard let chunk = try handle.read(upToCount: Int(min(65536, size - offset))), !chunk.isEmpty else { break }
                bytesRead += chunk.count
                offset += UInt64(chunk.count)
                pending.append(chunk)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 10) {
                    let line = pending[start..<end]
                    if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       let raw = QuotaValue.number(json["timestamp"]), raw > 0 {
                        let date = Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
                        if date >= cutoff && date <= now {
                            let tokenValue = QuotaValue.number(json["totalTokens"]) ?? 0
                            let tokens = tokenValue >= 0 && tokenValue < Double(Int.max) ? Int(tokenValue) : 0
                            entries.append(Entry(timestamp: date,
                                model: (json["resolvedModel"] as? String) ?? (json["model"] as? String) ?? "unknown",
                                provider: (json["provider"] as? String) ?? "unknown", tokens: tokens))
                        }
                    }
                    start = pending.index(after: end)
                }
                pending = Data(pending[start...])
            }
            let checkLength = min(offset, 128)
            try handle.seek(toOffset: offset - checkLength)
            checkpoint = try handle.read(upToCount: Int(checkLength)) ?? Data()
            isAvailable = true
        } catch {
            reset()
            fileID = nil
            isAvailable = false
        }
        entries.removeAll { $0.timestamp < cutoff || $0.timestamp > now }
        var models: [String: (model: String, provider: String, calls: Int, tokens: Int, date: Date)] = [:]
        var providers: [String: (calls: Int, tokens: Int)] = [:]
        var totalTokens = 0
        for entry in entries {
            let key = entry.provider + "\u{0}" + entry.model
            var row = models[key] ?? (entry.model, entry.provider, 0, 0, entry.timestamp)
            row.calls += 1
            row.tokens += entry.tokens
            row.date = max(row.date, entry.timestamp)
            models[key] = row
            var provider = providers[entry.provider] ?? (0, 0)
            provider.calls += 1
            provider.tokens += entry.tokens
            providers[entry.provider] = provider
            totalTokens += entry.tokens
        }
        var stats: [ModelUsageStat] = models.values.map {
            ModelUsageStat(model: $0.model, provider: $0.provider, calls: $0.calls, tokens: $0.tokens, lastSeen: $0.date)
        }
        stats.sort { lhs, rhs in
            if lhs.tokens == rhs.tokens { return lhs.id < rhs.id }
            return lhs.tokens > rhs.tokens
        }
        return (stats, entries.count, totalTokens, providers)
    }
}

enum ProviderQuotaParser {
    static func parse(data: Data) -> ProviderQuotaSnapshots? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["reports"] as? [[String: Any]] else {
            return nil
        }
        let google = parseGoogleQuotaSnapshot(reports: reports)
        let cursor = parseCursorQuotaSnapshot(reports: reports)
        guard google != nil || cursor != nil else { return nil }
        return ProviderQuotaSnapshots(google: google, cursor: cursor)
    }

    private static func parseGoogleQuotaSnapshot(reports: [[String: Any]]) -> GoogleQuotaSnapshot? {
        guard let report = reports.first(where: { $0["provider"] as? String == "google-antigravity" }),
              let quota = report["quota"] as? [String: Any] else {
            return nil
        }
        let rawWindows = quota["customWindows"] as? [[String: Any]] ?? []
        let windows: [SubQuotaWindow] = rawWindows.compactMap { item in
            guard let rawLabel = item["label"] as? String,
                  let rawPercent = number(item["percent"]) else { return nil }

            let normalized = rawLabel.lowercased()
            let label: String
            let hint: String?
            let weekly = normalized.contains("weekly")
            if normalized == "gem" || normalized.hasPrefix("gem (") || normalized.contains("gemini") {
                label = weekly ? "Gemini 周额度" : "Gemini 系列"
                hint = weekly ? nil : "Google 自研模型"
            } else if normalized == "cla" || normalized.hasPrefix("cla (") || normalized.contains("claude") {
                label = weekly ? "Claude 周额度" : "Claude 系列"
                hint = weekly ? nil : "第三方托管模型"
            } else {
                label = rawLabel
                hint = nil
            }

            let used = clampPercent(rawPercent)
            return SubQuotaWindow(
                label: label,
                hint: hint,
                usedPercent: used,
                remainingPercent: 100 - used,
                resetDate: dateFromEpoch(number(item["resetAt"]))
            )
        }
        guard !windows.isEmpty else { return nil }
        return GoogleQuotaSnapshot(
            subWindows: windows,
            resetDate: windows.compactMap(\.resetDate).min(),
            updatedAt: dateFromEpoch(number(report["updatedAt"]) ?? number(quota["updatedAt"]))
        )
    }

    private static func parseCursorQuotaSnapshot(reports: [[String: Any]]) -> CursorQuotaSnapshot? {
        guard let report = reports.first(where: { $0["provider"] as? String == "cursor" }),
              let quota = report["quota"] as? [String: Any] else {
            return nil
        }

        let monthlyUsed = number(quota["monthlyPercent"]).map(clampPercent)
        let monthlyReset = dateFromEpoch(number(quota["monthlyResetAt"]))
        let updatedAt = dateFromEpoch(number(report["updatedAt"]) ?? number(quota["updatedAt"]))
        let experimental = (report["reverseEngineered"] as? Bool) ?? false
        let rawWindows = quota["customWindows"] as? [[String: Any]] ?? []

        var windows: [SubQuotaWindow] = rawWindows.compactMap { item in
            guard let rawLabel = item["label"] as? String,
                  let rawPercent = number(item["percent"]) else { return nil }

            let normalized = rawLabel.lowercased()
            let label: String
            let hint: String?
            if normalized.contains("first-party") {
                label = "Cursor Models"
                hint = "Cursor 第一方模型"
            } else if normalized.contains("api usage") {
                label = "Other Models"
                hint = "Claude、GPT 等 API 用量"
            } else {
                label = rawLabel
                hint = nil
            }

            let used = clampPercent(rawPercent)
            return SubQuotaWindow(
                label: label,
                hint: hint,
                usedPercent: used,
                remainingPercent: 100 - used,
                resetDate: dateFromEpoch(number(item["resetAt"])) ?? monthlyReset
            )
        }

        if windows.isEmpty, let monthlyUsed {
            windows = [SubQuotaWindow(
                label: "Monthly usage",
                hint: "Cursor 月度综合用量",
                usedPercent: monthlyUsed,
                remainingPercent: 100 - monthlyUsed,
                resetDate: monthlyReset
            )]
        }

        guard !windows.isEmpty else { return nil }
        return CursorQuotaSnapshot(
            subWindows: windows,
            monthlyUsedPercent: monthlyUsed,
            resetDate: monthlyReset ?? windows.compactMap(\.resetDate).first,
            updatedAt: updatedAt,
            experimental: experimental
        )
    }

    private static func number(_ value: Any?) -> Double? { QuotaValue.number(value) }
    private static func clampPercent(_ value: Double) -> Double { min(100, max(0, value)) }
    private static func dateFromEpoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}
