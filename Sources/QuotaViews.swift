import Cocoa
import SwiftUI

private enum PanelStyle {
    static func color(used: Double) -> Color {
        used >= 90 ? .red : (used >= 70 ? .orange : .blue)
    }
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }
    static func reset(_ date: Date?) -> String {
        guard let date else { return "恢复时间未知" }
        if date <= Date() { return "已到恢复时间 · 待更新" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm 恢复" : "M月d日 HH:mm 恢复"
        return formatter.string(from: date)
    }
}

private struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct ProviderIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color).frame(width: 30, height: 30)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

private struct RemainingBar: View {
    let used: Double
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(PanelStyle.color(used: used))
                        .frame(width: geometry.size.width * max(0, min(100, 100 - used)) / 100)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private struct QuotaTile: View {
    let title: String
    let used: Double?
    let reset: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(used.map { String(Int((100 - $0).rounded())) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(used == nil ? "暂无数据" : "% 剩余")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(used.map { PanelStyle.color(used: $0) } ?? .secondary)
            if let used { RemainingBar(used: used) }
            else { Capsule().fill(Color.primary.opacity(0.07)).frame(height: 5) }
            Text(PanelStyle.reset(reset)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct AccountQuotaView: View {
    let account: OpenAiAccountItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(account.isMain ? "主账号" : account.name).font(.system(size: 12, weight: .medium))
                if let plan = account.plan {
                    Text(plan).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if account.resetCredits > 0 {
                    Label("\(account.resetCredits) 张重置券", systemImage: "ticket")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .help(account.email ?? account.name)
            HStack(spacing: 8) {
                QuotaTile(title: account.shortLabel, used: account.shortPercent, reset: account.shortResetDate)
                QuotaTile(title: "每周额度", used: account.weeklyPercent, reset: account.weeklyResetDate)
            }
            Text(QuotaValue.status(updatedAt: account.updatedAt, available: account.usedPercent != nil, failed: false))
                .font(.system(size: 10.5))
                .foregroundStyle(QuotaValue.isStale(account.updatedAt) ? Color.orange : .secondary)
        }
    }
}

private struct OpenAIQuotaCard: View {
    let accounts: [OpenAiAccountItem]
    @State private var expanded = false
    private var primary: OpenAiAccountItem? { accounts.first(where: { $0.isMain }) ?? accounts.first }
    private var secondary: [OpenAiAccountItem] { accounts.filter { $0.id != primary?.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ProviderIcon(symbol: "bolt.fill", color: .blue)
                Text("OpenAI").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(accounts.count) 个账号").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let primary { AccountQuotaView(account: primary) }
            else { Text("暂无额度数据 · 等待本地缓存").font(.system(size: 12)).foregroundStyle(.secondary) }
            if !secondary.isEmpty {
                DisclosureGroup("其他账号（\(secondary.count)）", isExpanded: $expanded) {
                    VStack(spacing: 14) {
                        ForEach(secondary) { account in
                            Divider()
                            AccountQuotaView(account: account)
                        }
                    }.padding(.top, 8)
                }
                .font(.system(size: 11))
            }
        }
        .modifier(PanelCard())
    }
}

private struct ProviderQuotaCard: View {
    let title: String
    let symbol: String
    let color: Color
    let identity: String
    let disabled: Bool
    let windows: [SubQuotaWindow]
    let status: String
    let experimental: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if disabled {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 9) {
                        ProviderIcon(symbol: symbol, color: .secondary)
                        Text(title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("已停用").font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + (expanded ? "，已停用，收起详情" : "，已停用，展开详情"))
            } else {
                HStack(spacing: 9) {
                    ProviderIcon(symbol: symbol, color: color)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if experimental {
                        Text("实验性").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if !disabled || expanded {
                details
            }
        }
        .modifier(PanelCard())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if windows.isEmpty {
                Text(disabled ? "该通道已停用，暂无可用额度报告。" : "暂未取得额度报告，稍后可重试刷新。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.label).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1f%% 剩余", window.remainingPercent))
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(PanelStyle.color(used: window.usedPercent))
                        }
                        RemainingBar(used: window.usedPercent)
                        Text(PanelStyle.reset(window.resetDate))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(status).font(.system(size: 10.5))
                .foregroundStyle(status.hasPrefix("已更新") ? Color.secondary : .orange)
            if disabled && expanded {
                Text(identity).font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .help(identity)
    }
}

private struct UsageRankingView: View {
    let models: [ModelUsageStat]
    let calls: Int
    let tokens: Int
    let available: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                metric("调用次数", value: available ? String(calls) : "—", unit: "次")
                metric("Token 用量", value: available ? PanelStyle.tokens(tokens) : "—", unit: "tokens")
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("模型排行").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("按 Token 用量").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if models.isEmpty {
                    Text(available ? "过去 24 小时暂无调用记录" : "用量日志暂不可读")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                } else {
                    ForEach(models.prefix(5)) { model in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(model.model).font(.system(size: 12, weight: .medium))
                                    .lineLimit(1).help(model.model)
                                Spacer(minLength: 10)
                                Text(PanelStyle.tokens(model.tokens))
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                            HStack {
                                Text(model.provider)
                                Spacer()
                                Text("\(model.calls) 次调用")
                            }
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            GeometryReader { geometry in
                                Capsule().fill(Color.blue.opacity(0.1))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.blue.opacity(0.7))
                                            .frame(width: geometry.size.width * CGFloat(model.tokens) / CGFloat(max(1, models.first?.tokens ?? 1)))
                                    }
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }.modifier(PanelCard())
            Text("最近 24 小时 · 统计本机 OpenCodex 调用记录")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }.modifier(PanelCard())
    }
}

struct PopoverContentView: View {
    @ObservedObject var dm: DataManager
    @State private var page = 0
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("查看内容", selection: $page) {
                Text("额度概览").tag(0)
                Text("24 小时用量").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if page == 0 {
                        OpenAIQuotaCard(accounts: dm.openAiAccounts)
                        ProviderQuotaCard(title: "Google · Antigravity", symbol: "sparkles", color: .purple,
                            identity: dm.googleEmail, disabled: dm.googleDisabled, windows: dm.googleSubWindows,
                            status: dm.googleQuotaStatusText, experimental: false)
                        ProviderQuotaCard(title: "Cursor", symbol: "cursorarrow.rays", color: .teal,
                            identity: dm.cursorUser, disabled: dm.cursorDisabled, windows: dm.cursorSubWindows,
                            status: dm.cursorQuotaStatusText, experimental: dm.cursorQuotaExperimental)
                    } else {
                        UsageRankingView(models: dm.topModels24h, calls: dm.totalCalls24h,
                            tokens: dm.totalTokens24h, available: dm.usageAvailable)
                    }
                }.padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderIcon(symbol: "bolt.fill", color: .blue)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("OpenCodex").font(.system(size: 17, weight: .semibold))
                    Text("v" + version).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("本机额度监控").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dm.refreshData(forceProviderQuotaRefresh: true) } label: {
                ZStack {
                    if dm.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)) }
                }.frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).disabled(dm.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(dm.isRefreshing ? "正在刷新" : "刷新额度")
            .help("刷新额度（⌘R）")
        }.padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(dm.isRefreshing ? "正在刷新…" : "本地检查 " + dm.lastRefreshTime.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("管理面板") {
                if let url = URL(string: "http://localhost:10100/") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link).font(.system(size: 11))
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .accessibilityLabel("退出 OpenCodex 额度看板").help("退出额度看板")
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}
