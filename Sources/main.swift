import Cocoa
import os
import SwiftUI

// MARK: - Models

struct OpenAiAccountItem: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let email: String?
    let plan: String?
    let isMain: Bool
    let usedPercent: Double
    let remainingPercent: Double
    let resetDate: Date?
    let resetCredits: Int
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
    var id: String { model }
    let model: String
    let provider: String
    let calls: Int
    let tokens: Int
    let lastSeen: Date
}

// MARK: - Data Manager

class DataManager: ObservableObject {
    @Published var openAiAccounts: [OpenAiAccountItem] = []
    @Published var googleSubWindows: [SubQuotaWindow] = []
    @Published var googleEmail: String = "Google CloudCode"
    @Published var googleDisabled: Bool = false
    @Published var googleResetText: String = "恢复时间未知"
    @Published var googleQuotaStatusText: String = "额度暂不可用"
    @Published var googleCalls24h: Int = 0
    @Published var googleTokens24h: Int = 0
    
    @Published var cursorSubWindows: [SubQuotaWindow] = []
    @Published var cursorUser: String = "Cursor Pro"
    @Published var cursorDisabled: Bool = false
    @Published var cursorResetDate: Date? = nil
    @Published var cursorResetText: String = "重置时间未知"
    @Published var cursorQuotaStatusText: String = "额度暂不可用"
    @Published var cursorQuotaExperimental: Bool = true
    @Published var cursorCalls24h: Int = 0
    @Published var cursorTokens24h: Int = 0
    
    @Published var topModels24h: [ModelUsageStat] = []
    @Published var totalCalls24h: Int = 0
    @Published var totalTokens24h: Int = 0
    @Published var lastRefreshTime: Date = Date()
    @Published var summaryTitle: String = "⚡️ ..."

    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "com.zhoujie.opencodex.menubar.refresh", qos: .utility)
    private let logger = Logger(subsystem: "com.zhoujie.opencodex.menubar", category: "quota")
    private var cachedProviderQuotas: ProviderQuotaSnapshots?
    private var lastProviderQuotaFetchAttempt = Date.distantPast
    private let providerQuotaRefreshInterval: TimeInterval = 60

    init() {
        refreshData()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    func refreshData(forceProviderQuotaRefresh: Bool = false) {
        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            let (models, calls, tokens, providerStats) = self.loadUsageStats()
            let providerQuotas = self.loadProviderQuotasIfNeeded(forceRefresh: forceProviderQuotaRefresh)
            let sectionData = self.loadSectionData(providerStats: providerStats, providerQuotas: providerQuotas)

            DispatchQueue.main.async {
                self.openAiAccounts = sectionData.openAiAccounts
                self.googleSubWindows = sectionData.googleSubWindows
                self.googleEmail = sectionData.googleEmail
                self.googleDisabled = sectionData.googleDisabled
                self.googleResetText = sectionData.googleResetText
                self.googleQuotaStatusText = sectionData.googleQuotaStatusText
                self.googleCalls24h = sectionData.googleCalls24h
                self.googleTokens24h = sectionData.googleTokens24h
                
                self.cursorSubWindows = sectionData.cursorSubWindows
                self.cursorUser = sectionData.cursorUser
                self.cursorDisabled = sectionData.cursorDisabled
                self.cursorResetDate = sectionData.cursorResetDate
                self.cursorResetText = sectionData.cursorResetText
                self.cursorQuotaStatusText = sectionData.cursorQuotaStatusText
                self.cursorQuotaExperimental = sectionData.cursorQuotaExperimental
                self.cursorCalls24h = sectionData.cursorCalls24h
                self.cursorTokens24h = sectionData.cursorTokens24h
                
                self.topModels24h = models
                self.totalCalls24h = calls
                self.totalTokens24h = tokens
                self.lastRefreshTime = Date()

                if let mainOpenAI = sectionData.openAiAccounts.first(where: { $0.isMain }) {
                    let rem = Int(round(mainOpenAI.remainingPercent))
                    self.summaryTitle = "⚡️ " + String(rem) + "%"
                } else {
                    self.summaryTitle = "⚡️ OpenCodex"
                }
            }
        }
    }

    private func loadSectionData(
        providerStats: [String: (calls: Int, tokens: Int)],
        providerQuotas: ProviderQuotaSnapshots?
    ) -> ProviderSectionData {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let quotaCacheURL = home.appendingPathComponent(".opencodex/codex-quota-cache.json")
        let configURL = home.appendingPathComponent(".opencodex/config.json")
        let authURL = home.appendingPathComponent(".opencodex/auth.json")

        var accountsMeta: [String: [String: Any]] = [:]
        var configProviders: [String: Any] = [:]

        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let accounts = cfg["codexAccounts"] as? [[String: Any]] {
                for acc in accounts {
                    if let id = acc["id"] as? String { accountsMeta[id] = acc }
                }
            }
            if let pMap = cfg["providers"] as? [String: Any] {
                configProviders = pMap
            }
        }

        var authData: [String: Any] = [:]
        if let data = try? Data(contentsOf: authURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            authData = json
        }

        // 1. OpenAI 账号列表
        var openAiItems: [OpenAiAccountItem] = []
        if let data = try? Data(contentsOf: quotaCacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let quotaMap = json["quotas"] as? [String: [String: Any]] {
            for (key, q) in quotaMap {
                let isMain = (key == "__main__")
                let meta = accountsMeta[key]
                let displayName = isMain ? "主账号 (Main)" : ((meta?["alias"] as? String) ?? (meta?["logLabel"] as? String) ?? key)
                let email = (meta?["email"] as? String) ?? (isMain ? "主会话授权" : nil)
                let plan = ((meta?["plan"] as? String)?.uppercased()) ?? (isMain ? "PLUS" : nil)
                let used = (q["weeklyPercent"] as? Double) ?? 0.0
                let rem = max(0, 100.0 - used)
                let resetAt = q["weeklyResetAt"] as? Double
                let resetDate = resetAt.flatMap { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000.0 : $0) }
                let credits = (q["resetCredits"] as? Int) ?? 0

                openAiItems.append(OpenAiAccountItem(
                    key: key,
                    name: displayName,
                    email: email,
                    plan: plan,
                    isMain: isMain,
                    usedPercent: used,
                    remainingPercent: rem,
                    resetDate: resetDate,
                    resetCredits: credits
                ))
            }
        }
        openAiItems.sort {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.remainingPercent > $1.remainingPercent
        }

        // 2. Google Antigravity：额度由 OpenCodeX 的 provider quota 报告提供。
        let googleCfg = configProviders["google-antigravity"] as? [String: Any]
        let googleAuth = authData["google-antigravity"] as? [String: Any]
        let googleAccounts = googleAuth?["accounts"] as? [[String: Any]]
        let googleCred = googleAccounts?.first?["credential"] as? [String: Any]
        let googleEmail = googleCred?["email"] as? String ?? "Google CloudCode"
        let googleStat = providerStats["google-antigravity"] ?? (0, 0)
        let googleDisabled = (googleCfg?["disabled"] as? Bool) ?? false

        let googleQuota = providerQuotas?.google
        let googleSubWindows = googleQuota?.subWindows ?? []
        let googleResetFormatter = DateFormatter()
        googleResetFormatter.dateFormat = "M-d HH:mm 最近恢复"
        let googleResetText = googleQuota?.resetDate.map(googleResetFormatter.string(from:)) ?? "恢复时间未知"
        let quotaStatusFormatter = DateFormatter()
        quotaStatusFormatter.dateFormat = "HH:mm"
        let googleQuotaStatusText = googleQuota?.updatedAt
            .map { "实时 · 更新 " + quotaStatusFormatter.string(from: $0) }
            ?? (googleQuota == nil ? "额度暂不可用" : "实时 · 更新时间未知")

        // 3. Cursor：额度由 OpenCodeX 的 provider quota 报告提供。
        let cursorCfg = configProviders["cursor"] as? [String: Any]
        let cursorAuth = authData["cursor"] as? [String: Any]
        let cursorAccounts = cursorAuth?["accounts"] as? [[String: Any]]
        let cursorCred = cursorAccounts?.first?["credential"] as? [String: Any]
        let cursorUser = (cursorCred?["accountId"] as? String)?.components(separatedBy: "|").last ?? "Cursor Pro"
        let cursorStat = providerStats["cursor"] ?? (0, 0)
        let cursorDisabled = (cursorCfg?["disabled"] as? Bool) ?? false

        let cursorQuota = providerQuotas?.cursor
        let cursorResetDate = cursorQuota?.resetDate
        let resetFormatter = DateFormatter()
        resetFormatter.dateFormat = "M-d HH:mm 月度重置"
        let cursorResetText = cursorResetDate.map(resetFormatter.string(from:)) ?? "重置时间未知"

        let cursorQuotaStatusText: String
        if let quota = cursorQuota {
            let prefix = quota.experimental ? "实验性" : "实时"
            let updated = quota.updatedAt.map { quotaStatusFormatter.string(from: $0) } ?? "未知"
            if let monthly = quota.monthlyUsedPercent {
                cursorQuotaStatusText = String(format: "%@ · 综合已用 %.1f%% · 更新 %@", prefix, monthly, updated)
            } else {
                cursorQuotaStatusText = "\(prefix) · 更新 \(updated)"
            }
        } else {
            cursorQuotaStatusText = "额度暂不可用"
        }

        let cursorSubWindows = cursorQuota?.subWindows ?? []

        return ProviderSectionData(
            openAiAccounts: openAiItems,
            googleSubWindows: googleSubWindows,
            googleEmail: googleEmail,
            googleDisabled: googleDisabled,
            googleResetText: googleResetText,
            googleQuotaStatusText: googleQuotaStatusText,
            googleCalls24h: googleStat.calls,
            googleTokens24h: googleStat.tokens,
            cursorSubWindows: cursorSubWindows,
            cursorUser: cursorUser,
            cursorDisabled: cursorDisabled,
            cursorResetDate: cursorResetDate,
            cursorResetText: cursorResetText,
            cursorQuotaStatusText: cursorQuotaStatusText,
            cursorQuotaExperimental: cursorQuota?.experimental ?? true,
            cursorCalls24h: cursorStat.calls,
            cursorTokens24h: cursorStat.tokens
        )
    }

    private func loadProviderQuotasIfNeeded(forceRefresh: Bool) -> ProviderQuotaSnapshots? {
        let now = Date()
        if !forceRefresh,
           let cached = cachedProviderQuotas,
           now.timeIntervalSince(lastProviderQuotaFetchAttempt) < providerQuotaRefreshInterval {
            return cached
        }

        lastProviderQuotaFetchAttempt = now
        guard let data = runOpenCodexQuotaCommand(forceRefresh: forceRefresh),
              let parsed = parseProviderQuotaSnapshots(data: data) else {
            logger.error("Provider quota refresh failed; retaining the last valid snapshots")
            return cachedProviderQuotas
        }

        let snapshot = ProviderQuotaSnapshots(
            google: parsed.google ?? cachedProviderQuotas?.google,
            cursor: parsed.cursor ?? cachedProviderQuotas?.cursor
        )
        cachedProviderQuotas = snapshot
        if let google = snapshot.google {
            let summary = quotaWindowSummary(google.subWindows)
            logger.info("Google quota loaded: \(summary, privacy: .public)")
        }
        if let cursor = snapshot.cursor {
            let summary = quotaWindowSummary(cursor.subWindows)
            logger.info("Cursor quota loaded: \(summary, privacy: .public)")
        }
        return snapshot
    }

    private func quotaWindowSummary(_ windows: [SubQuotaWindow]) -> String {
        windows
            .map { String(format: "%@=%.2f%%", $0.label, $0.usedPercent) }
            .joined(separator: ", ")
    }

    private func runOpenCodexQuotaCommand(forceRefresh: Bool) -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ocx", "provider", "quota"]
            + (forceRefresh ? ["--refresh"] : [])
            + ["--json"]
        let preferredPaths = [
            home + "/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        process.environment = [
            "HOME": home,
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": preferredPaths.joined(separator: ":"),
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            logger.error("Unable to launch ocx: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if finished.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            logger.error("Timed out while loading provider quota")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logger.error("ocx provider quota exited with status \(process.terminationStatus)")
            return nil
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func parseProviderQuotaSnapshots(data: Data) -> ProviderQuotaSnapshots? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["reports"] as? [[String: Any]] else {
            return nil
        }
        let google = parseGoogleQuotaSnapshot(reports: reports)
        let cursor = parseCursorQuotaSnapshot(reports: reports)
        guard google != nil || cursor != nil else { return nil }
        return ProviderQuotaSnapshots(google: google, cursor: cursor)
    }

    private func parseGoogleQuotaSnapshot(reports: [[String: Any]]) -> GoogleQuotaSnapshot? {
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
            if normalized == "gem" || normalized.contains("gemini") {
                label = "Gemini 系列"
                hint = "Google 自研模型"
            } else if normalized == "cla" || normalized.contains("claude") {
                label = "Claude 系列"
                hint = "第三方托管模型"
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

    private func parseCursorQuotaSnapshot(reports: [[String: Any]]) -> CursorQuotaSnapshot? {
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

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private func dateFromEpoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }

    private func loadUsageStats() -> ([ModelUsageStat], Int, Int, [String: (calls: Int, tokens: Int)]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usageURL = home.appendingPathComponent(".opencodex/usage.jsonl")

        guard let fileContent = try? String(contentsOf: usageURL, encoding: .utf8) else {
            return ([], 0, 0, [:])
        }

        let now = Date().timeIntervalSince1970 * 1000.0
        let dayAgo = now - 24 * 3600 * 1000.0

        var modelCounts: [String: (provider: String, calls: Int, tokens: Int, lastSeen: Double)] = [:]
        var providerCounts: [String: (calls: Int, tokens: Int)] = [:]
        var total24hCalls = 0
        var total24hTokens = 0

        let lines = fileContent.components(separatedBy: CharacterSet.newlines)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let ts = (json["timestamp"] as? Double) ?? 0
            if ts < dayAgo { continue }

            let model = (json["model"] as? String) ?? (json["resolvedModel"] as? String) ?? "unknown"
            let provider = (json["provider"] as? String) ?? "unknown"
            let tokens = (json["totalTokens"] as? Int) ?? 0

            total24hCalls += 1
            total24hTokens += tokens

            var curr = modelCounts[model] ?? (provider: provider, calls: 0, tokens: 0, lastSeen: ts)
            curr.calls += 1
            curr.tokens += tokens
            curr.lastSeen = max(curr.lastSeen, ts)
            modelCounts[model] = curr

            var pCurr = providerCounts[provider] ?? (0, 0)
            pCurr.calls += 1
            pCurr.tokens += tokens
            providerCounts[provider] = pCurr
        }

        var stats: [ModelUsageStat] = []
        for (m, d) in modelCounts {
            let lastDate = Date(timeIntervalSince1970: d.lastSeen > 1e11 ? d.lastSeen / 1000.0 : d.lastSeen)
            stats.append(ModelUsageStat(model: m, provider: d.provider, calls: d.calls, tokens: d.tokens, lastSeen: lastDate))
        }

        stats.sort { $0.tokens > $1.tokens }
        return (stats, total24hCalls, total24hTokens, providerCounts)
    }
}

// MARK: - SwiftUI Views

struct QuotaProgressView: View {
    let percent: Double

    var progressColor: Color {
        if percent > 85 { return Color.red }
        if percent > 60 { return Color.orange }
        return Color.blue
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6.5)

                RoundedRectangle(cornerRadius: 3.5)
                    .fill(
                        LinearGradient(
                            colors: [progressColor.opacity(0.85), progressColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, geo.size.width * CGFloat(min(100, max(0, percent)) / 100.0)), height: 6.5)
            }
        }
        .frame(height: 6.5)
    }
}

struct OpenAiAccountRowView: View {
    let acc: OpenAiAccountItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: acc.isMain ? "crown.fill" : "person.fill")
                        .foregroundColor(acc.isMain ? Color.orange : Color.blue)
                        .font(.system(size: 10, weight: .bold))

                    Text(acc.name)
                        .font(.system(size: 11, weight: .semibold))
                }

                if let email = acc.email {
                    Text("(" + email + ")")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(String(Int(round(acc.usedPercent))) + "% 已用")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(acc.usedPercent > 80 ? .red : .primary)
                Text("(余 " + String(Int(round(acc.remainingPercent))) + "%)")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }

            QuotaProgressView(percent: acc.usedPercent)

            HStack {
                if let reset = acc.resetDate {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(formatResetTime(reset))
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }
                Spacer()
                if acc.resetCredits > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "ticket.fill")
                        Text("重置券: " + String(acc.resetCredits))
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func formatResetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm 周重置"
        return formatter.string(from: date)
    }
}

// 统一的 OpenAI 多账号聚合卡片
struct OpenAiUnifiedCardView: View {
    let accounts: [OpenAiAccountItem]
    @State private var isExpanded: Bool = false

    var primaryAccounts: [OpenAiAccountItem] {
        let mains = accounts.filter { $0.isMain }
        return mains.isEmpty ? Array(accounts.prefix(1)) : mains
    }

    var secondaryAccounts: [OpenAiAccountItem] {
        let primaryIDs = Set(primaryAccounts.map { $0.id })
        return accounts.filter { !primaryIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.square.filled.on.square")
                        .foregroundColor(Color.orange)
                        .font(.system(size: 12, weight: .bold))

                    Text("OpenAI · 账号池")
                        .font(.system(size: 13, weight: .bold))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("共 " + String(accounts.count) + " 个账号")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)

                    Text("多账号轮询")
                        .font(.system(size: 8.5, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .foregroundColor(Color.orange)
                        .clipShape(Capsule())
                }
            }

            VStack(spacing: 8) {
                ForEach(primaryAccounts) { acc in
                    OpenAiAccountRowView(acc: acc)
                }
            }

            if !secondaryAccounts.isEmpty {
                if isExpanded {
                    VStack(spacing: 8) {
                        ForEach(secondaryAccounts) { acc in
                            OpenAiAccountRowView(acc: acc)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))

                        Text(isExpanded ? "收起备用/已用尽账号" : ("展开其他 " + String(secondaryAccounts.count) + " 个备用账号" + (secondaryAccounts.contains(where: { $0.usedPercent >= 100 }) ? " (含用尽)" : "")))
                            .font(.system(size: 9.5, weight: .medium))

                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// Google 资源池卡片（带重置与恢复周期）
struct GoogleAntigravityCardView: View {
    let email: String
    let disabled: Bool
    let subWindows: [SubQuotaWindow]
    let resetText: String
    let statusText: String
    let calls24h: Int
    let tokens24h: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(Color.purple)
                        .font(.system(size: 11.5, weight: .bold))

                    Text("Google · Antigravity")
                        .font(.system(size: 12.5, weight: .bold))
                }

                Spacer()

                Text(disabled ? "DISABLED" : "CLOUDRUN")
                    .font(.system(size: 8.5, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(Color.purple)
                    .clipShape(Capsule())
            }

            Text(email)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(statusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(statusText == "额度暂不可用" ? .orange : .secondary)
                .lineLimit(1)

            if subWindows.isEmpty {
                Text("OpenCodeX 暂未返回 Google 配额报告")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(subWindows) { win in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(win.label)
                                    .font(.system(size: 10, weight: .semibold))
                                if let hint = win.hint {
                                    Text("· " + hint)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f%% used", win.usedPercent))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(win.usedPercent > 80 ? .red : .primary)
                            }
                            QuotaProgressView(percent: win.usedPercent)
                        }
                    }
                }
                .padding(.top, 1)
            }

            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(resetText)
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)

                Spacer()

                if calls24h > 0 {
                    Text("OpenCodeX 24h: " + String(calls24h) + "次 · " + formatTokens(tokens24h))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.purple)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return String(count)
        }
    }
}

// Cursor 资源池卡片（带月度账单周期重置时间）
struct CursorQuotaCardView: View {
    let user: String
    let disabled: Bool
    let subWindows: [SubQuotaWindow]
    let resetText: String
    let statusText: String
    let experimental: Bool
    let calls24h: Int
    let tokens24h: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.rays")
                        .foregroundColor(Color.teal)
                        .font(.system(size: 11.5, weight: .bold))

                    Text("Cursor · Included in Pro")
                        .font(.system(size: 12.5, weight: .bold))
                }

                Spacer()

                Text(disabled ? "DISABLED" : (experimental ? "PRO · EXP" : "PRO"))
                    .font(.system(size: 8.5, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.12))
                    .foregroundColor(Color.teal)
                    .clipShape(Capsule())
            }

            Text("User: " + user)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(statusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(statusText == "额度暂不可用" ? .orange : .secondary)
                .lineLimit(1)

            if subWindows.isEmpty {
                Text("OpenCodeX 暂未返回 Cursor 配额报告")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 7) {
                    ForEach(subWindows) { win in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(win.label)
                                    .font(.system(size: 10.5, weight: .semibold))
                                if let hint = win.hint {
                                    Text("· " + hint)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(String(format: "%.1f%% used", win.usedPercent))
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(win.usedPercent > 80 ? .red : .primary)
                            }
                            QuotaProgressView(percent: win.usedPercent)
                        }
                    }
                }
                .padding(.top, 1)
            }

            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(resetText)
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)

                Spacer()

                if calls24h > 0 {
                    Text("OpenCodeX 24h: " + String(calls24h) + "次 · " + formatTokens(tokens24h))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.teal)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return String(count)
        }
    }
}

struct PopoverContentView: View {
    @ObservedObject var dm: DataManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenCodex 全模型额度")
                        .font(.system(size: 13.5, weight: .bold))
                    Text("OpenAI · Google · Cursor 三大通道概览")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    dm.refreshData(forceProviderQuotaRefresh: true)
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("立即刷新数据")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("核心模型通道配额")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("OpenAI · Google · Cursor")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        // 1. OpenAI 多账号卡片 (周重置)
                        if !dm.openAiAccounts.isEmpty {
                            OpenAiUnifiedCardView(accounts: dm.openAiAccounts)
                        }

                        // 2. Google Antigravity 卡片 (滑动窗口恢复)
                        GoogleAntigravityCardView(
                            email: dm.googleEmail,
                            disabled: dm.googleDisabled,
                            subWindows: dm.googleSubWindows,
                            resetText: dm.googleResetText,
                            statusText: dm.googleQuotaStatusText,
                            calls24h: dm.googleCalls24h,
                            tokens24h: dm.googleTokens24h
                        )

                        // 3. Cursor 官方规范卡片 (月度账单周期重置)
                        CursorQuotaCardView(
                            user: dm.cursorUser,
                            disabled: dm.cursorDisabled,
                            subWindows: dm.cursorSubWindows,
                            resetText: dm.cursorResetText,
                            statusText: dm.cursorQuotaStatusText,
                            experimental: dm.cursorQuotaExperimental,
                            calls24h: dm.cursorCalls24h,
                            tokens24h: dm.cursorTokens24h
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("24小时模型消耗分析")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(dm.totalCalls24h) + " 次 · " + formatTokens(dm.totalTokens24h) + " tokens")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(Color.blue)
                        }

                        if dm.topModels24h.isEmpty {
                            Text("过去 24 小时暂无调用记录")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 5) {
                                ForEach(dm.topModels24h.prefix(5)) { stat in
                                    HStack {
                                        Text(stat.model)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(String(stat.calls) + "次")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(formatTokens(stat.tokens))
                                            .font(.system(size: 10.5, weight: .bold))
                                            .frame(width: 60, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 500)

            Divider()

            // Footer
            HStack {
                Text("刷新: " + formatUpdateTime(dm.lastRefreshTime))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    if let url = URL(string: "http://localhost:10100/") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "safari")
                        Text("管理面板")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)

                Text("·")
                    .foregroundColor(.secondary)

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 340)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return String(count)
        }
    }

    private func formatUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let dataManager = DataManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⚡️ ..."
            button.action = #selector(togglePopover)
            button.target = self
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 340, height: 540)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PopoverContentView(dm: dataManager))
        self.popover = pop

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateButtonTitle()
        }
    }

    private func updateButtonTitle() {
        if let button = statusItem?.button {
            button.title = dataManager.summaryTitle
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            dataManager.refreshData()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
