import BavbavCore
import SwiftUI

struct ModelSettingsPanelView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    private var shortcutScope: String {
        !store.settingsIsChoosing ? "models.rows" : (store.settingsRow == .model ? "models.model" : "models.effort")
    }
    @ObservedObject var store: OverlayStore

    var body: some View {
        ZStack {
            BavbavTheme.background.opacity(0.99).panelBackdrop()
            VStack(spacing: 0) {
                header
                Divider().overlay(BavbavTheme.border)
                VStack(spacing: 6) {
                    settingRow(.model)
                    settingRow(.effort)
                    if store.settingsIsChoosing, let choice = store.settingsPreviewChoice {
                        choicePreview(choice)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxHeight: .infinity, alignment: .top)
                Divider().overlay(BavbavTheme.border)
                usageStrip
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                Divider().overlay(BavbavTheme.border)
                footer
                    .padding(.horizontal, 12)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    store.settingsIsChoosing ? BavbavTheme.warning.opacity(0.75) : BavbavTheme.border,
                    lineWidth: 1
                )
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("04")
                .font(BavbavTheme.mono(9, weight: .bold))
                .foregroundStyle(BavbavTheme.background).readableForeground()
                .frame(width: 24, height: 24)
                .background(BavbavTheme.warning.panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text("WRITE CONTROL")
                    .font(BavbavTheme.mono(11, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                Text((store.detailThread?.title ?? "NO ACTIVE CHAT").uppercased())
                    .font(BavbavTheme.mono(8, weight: .medium))
                    .foregroundStyle(store.detailThread == nil ? BavbavTheme.warning : BavbavTheme.muted).readableForeground()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.settingsLoading {
                ProgressView().controlSize(.small).tint(BavbavTheme.warning)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.detailThread == nil ? BavbavTheme.muted : BavbavTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("FULL ACCESS")
                        .font(BavbavTheme.mono(7, weight: .bold))
                        .foregroundStyle(store.detailThread == nil ? BavbavTheme.muted : BavbavTheme.warning).readableForeground()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private func settingRow(_ row: SettingsRow) -> some View {
        let selected = store.settingsRow == row
        let committedIsSet = row == .model ? store.modelIsSet : store.effortIsSet
        let committedIsAutomatic = row == .model ? store.modelIsAutomatic : store.effortIsAutomatic
        let isSet = selected && store.settingsIsChoosing
            ? store.settingsPreviewChoice?.value != nil
            : committedIsSet
        let isAutomatic = selected && store.settingsIsChoosing
            ? store.settingsPreviewChoice?.value == nil
            : committedIsAutomatic
        let value: String = {
            if selected, store.settingsIsChoosing, let preview = store.settingsPreviewChoice {
                return preview.label
            }
            return row == .model ? store.effectiveModelName.uppercased() : store.effectiveEffortName.uppercased()
        }()

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? (store.settingsIsChoosing ? BavbavTheme.warning : BavbavTheme.accent) : .clear)
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(BavbavTheme.mono(8, weight: .bold))
                    .foregroundStyle(selected ? BavbavTheme.accent : BavbavTheme.muted).readableForeground()
                Text(value)
                    .font(BavbavTheme.mono(10, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            SetStateBadge(isSet: isSet, isAutomatic: isAutomatic)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background((selected ? BavbavTheme.raised : .clear).panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func choicePreview(_ choice: SettingsChoice) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", store.settingsChoiceIndex + 1))
                .foregroundStyle(BavbavTheme.warning).readableForeground()
            Text(choice.detail.isEmpty ? "\(shortcuts.key(shortcutScope + ".open.key")) TO SET" : choice.detail.uppercased())
                .foregroundStyle(BavbavTheme.muted).readableForeground()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(BavbavTheme.mono(8, weight: .medium))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(BavbavTheme.surface.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var usageStrip: some View {
        if let limits = store.rateLimits {
            HStack(spacing: 12) {
                if let primary = limits.primary {
                    LimitCell(window: primary)
                }
                if let secondary = limits.secondary {
                    LimitCell(window: secondary)
                }
                Spacer(minLength: 0)
                if let today = store.accountUsage?.daily.max(by: { $0.startDate < $1.startDate }) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("TODAY")
                            .foregroundStyle(BavbavTheme.muted).readableForeground()
                        Text(compactNumber(today.tokens))
                            .foregroundStyle(BavbavTheme.cyan).readableForeground()
                    }
                    .font(BavbavTheme.mono(8, weight: .bold))
                }
            }
        } else {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1)
                    .stroke(BavbavTheme.muted, lineWidth: 1)
                    .frame(width: 9, height: 9)
                Text(store.settingsError ?? "LIMIT SIGNAL WAITING")
                    .font(BavbavTheme.mono(8, weight: .medium))
                    .foregroundStyle(store.settingsError == nil ? BavbavTheme.muted : BavbavTheme.warning).readableForeground()
                    .lineLimit(2)
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerKey(shortcuts.key(shortcutScope + ".up.key"), "↑")
            footerKey(shortcuts.key(shortcutScope + ".down.key"), "↓")
            footerKey(shortcuts.key(shortcutScope + ".open.key"), store.settingsIsChoosing ? "SET" : "EDIT")
            footerKey(shortcuts.key(shortcutScope + ".close.key"), "CLOSE")
            Spacer(minLength: 0)
        }
    }

    private func footerKey(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key).foregroundStyle(BavbavTheme.text).readableForeground()
            Text(action).foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .font(BavbavTheme.mono(7, weight: .bold))
    }

    private func compactNumber(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private struct SetStateBadge: View {
    let isSet: Bool
    let isAutomatic: Bool

    private var label: String {
        if isSet { return "SET" }
        if isAutomatic { return "AUTO" }
        return "WAIT"
    }

    private var color: Color {
        if isSet { return BavbavTheme.accent }
        if isAutomatic { return BavbavTheme.cyan }
        return BavbavTheme.muted
    }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isSet || isAutomatic ? color : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 1)
                        .stroke(isSet || isAutomatic ? .clear : BavbavTheme.muted, lineWidth: 1)
                }
                .frame(width: 8, height: 8)
            Text(label)
        }
        .font(BavbavTheme.mono(7, weight: .bold))
        .foregroundStyle(color).readableForeground()
    }
}

private struct LimitCell: View {
    let window: CodexRateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(durationLabel)
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                Text("\(window.remainingPercent)% LEFT")
                    .foregroundStyle(color).readableForeground()
            }
            .font(BavbavTheme.mono(8, weight: .bold))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(BavbavTheme.raised).panelBackdrop()
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }
            .frame(width: 72, height: 3)
        }
    }

    private var durationLabel: String {
        guard let minutes = window.durationMinutes else { return "LIMIT" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }

    private var color: Color {
        if window.remainingPercent <= 10 { return BavbavTheme.danger }
        if window.remainingPercent <= 30 { return BavbavTheme.warning }
        return BavbavTheme.accent
    }
}
