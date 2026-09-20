import Cocoa
import os
import SwiftUI
import Combine

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

    @Published private(set) var isRefreshing = false
    @Published private(set) var usageAvailable = true
    private let usageReader = UsageLogReader()
    private var googleRefreshFailed = false
    private var cursorRefreshFailed = false
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
        timer?.tolerance = 2
    }

    func refreshData(forceProviderQuotaRefresh: Bool = false) {
        // All callers are on the main thread; coalesce timer, click and popover requests.
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            let (models, calls, tokens, providerStats) = self.loadUsageStats()
            let localData = self.loadSectionData(providerStats: providerStats, providerQuotas: self.cachedProviderQuotas)
            DispatchQueue.main.async {
                self.openAiAccounts = localData.openAiAccounts
                self.summaryTitle = localData.openAiAccounts.first(where: { $0.isMain })?.summary() ?? "⚡️ --"
            }
            let providerQuotas = self.loadProviderQuotasIfNeeded(forceRefresh: forceProviderQuotaRefresh)
            let sectionData = self.loadSectionData(providerStats: providerStats, providerQuotas: providerQuotas)

            let usageAvailable = self.usageReader.isAvailable
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.usageAvailable = usageAvailable
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

                self.summaryTitle = sectionData.openAiAccounts.first(where: { $0.isMain })?.summary() ?? "⚡️ --"
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
                let plan = (meta?["plan"] as? String)?.uppercased()
                
                let weeklyUsed = QuotaValue.percent(q["weeklyPercent"])
                let weeklyRem = weeklyUsed.map { 100 - $0 }
                let weeklyResetAt = q["weeklyResetAt"] as? Double
                let weeklyResetDate = weeklyResetAt.flatMap { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000.0 : $0) }
                
                let shortUsed = QuotaValue.percent(q["shortPercent"])
                let shortRem = shortUsed.map { max(0, 100.0 - $0) }
                let shortResetAt = q["shortResetAt"] as? Double
                let shortResetDate = shortResetAt.flatMap { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000.0 : $0) }
                let shortWindowSeconds = q["shortWindowSeconds"] as? Int
                
                let credits = (q["resetCredits"] as? Int) ?? 0

                openAiItems.append(OpenAiAccountItem(
                    key: key,
                    name: displayName,
                    email: email,
                    plan: plan,
                    isMain: isMain,
                    shortPercent: shortUsed,
                    shortRemainingPercent: shortRem,
                    shortResetDate: shortResetDate,
                    shortWindowSeconds: shortWindowSeconds,
                    weeklyPercent: weeklyUsed,
                    weeklyRemainingPercent: weeklyRem,
                    weeklyResetDate: weeklyResetDate,
                    resetCredits: credits,
                    updatedAt: dateFromEpoch(number(q["updatedAt"]))
                ))
            }
        }
        openAiItems.sort {
            if $0.isMain != $1.isMain { return $0.isMain }
            return ($0.remainingPercent ?? -1) == ($1.remainingPercent ?? -1)
                ? $0.key < $1.key : ($0.remainingPercent ?? -1) > ($1.remainingPercent ?? -1)
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
        let googleQuotaStatusText = QuotaValue.status(updatedAt: googleQuota?.updatedAt,
            available: googleQuota != nil, failed: googleRefreshFailed)

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

        let cursorQuotaStatusText = QuotaValue.status(updatedAt: cursorQuota?.updatedAt,
            available: cursorQuota != nil, failed: cursorRefreshFailed)

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
           now.timeIntervalSince(lastProviderQuotaFetchAttempt) < providerQuotaRefreshInterval {
            return cachedProviderQuotas
        }

        lastProviderQuotaFetchAttempt = now
        guard let data = runOpenCodexQuotaCommand(forceRefresh: forceRefresh),
              let parsed = ProviderQuotaParser.parse(data: data) else {
            googleRefreshFailed = true
            cursorRefreshFailed = true
            logger.error("Provider quota refresh failed; retaining the last valid snapshots")
            return cachedProviderQuotas
        }

        googleRefreshFailed = parsed.google == nil
        cursorRefreshFailed = parsed.cursor == nil
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
        let preferredPaths = [
            home + "/.local/bin",
            home + "/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let environment = [
            "HOME": home,
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": preferredPaths.joined(separator: ":"),
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        do {
            return try QuotaCommand.run(executable: "/usr/bin/env",
                arguments: ["ocx", "provider", "quota"] + (forceRefresh ? ["--refresh"] : []) + ["--json"],
                environment: environment)
        } catch {
            logger.error("Provider quota command failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func number(_ value: Any?) -> Double? {
        QuotaValue.number(value)
    }

    private func dateFromEpoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }

    private func loadUsageStats() -> ([ModelUsageStat], Int, Int, [String: (calls: Int, tokens: Int)]) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencodex/usage.jsonl")
        return usageReader.load(url: url)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let dataManager = DataManager()
    private var titleSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⚡️ ..."
            button.action = #selector(togglePopover)
            button.target = self
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 400, height: min(680, (NSScreen.main?.visibleFrame.height ?? 740) - 60))
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PopoverContentView(dm: dataManager))
        self.popover = pop

        titleSubscription = dataManager.$summaryTitle.removeDuplicates().sink { [weak self] title in
            self?.statusItem?.button?.title = title
            self?.statusItem?.button?.setAccessibilityLabel("OpenCodex 额度 " + title)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if popover?.isShown != true { togglePopover() }
        return true
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
