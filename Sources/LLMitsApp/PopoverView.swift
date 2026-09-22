import SwiftUI
import LLMitsCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateModel
    let onRequestUpdate: (AvailableUpdate) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("LLMits").font(.headline)
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                    .opacity(updates.isInstalling || model.isRefreshing ? 1 : 0)
                    .accessibilityHidden(!updates.isInstalling && !model.isRefreshing)
                if let update = updates.availableUpdate {
                    Button { onRequestUpdate(update) } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(updates.isInstalling)
                    .help("LLMits \(update.version) is available")
                } else {
                    Button { Task { await model.manualRefresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefreshing)
                    .help("Refresh quotas")
                }
            }

            if model.connectedSnapshots.isEmpty {
                ContentUnavailableView(
                    model.connectedProviders.isEmpty ? "No providers connected" : "Quota data unavailable",
                    systemImage: model.connectedProviders.isEmpty ? "link.badge.plus" : "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text(model.connectedProviders.isEmpty ? "Open Settings to connect a subscription." : "Refresh or check the connection in Settings.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.connectedSnapshots) { snapshot in
                            ProviderCard(
                                snapshot: snapshot,
                                mode: model.preferences.displayMode,
                                staleAfter: TimeInterval(model.preferences.pollingMinutes * 60),
                                isShownInMenuBar: model.isShownInMenuBar(snapshot.provider),
                                canToggleMenuBar: model.canToggleMenuBar(snapshot.provider),
                                onToggleMenuBar: {
                                    model.setMenuBarProvider(snapshot.provider, enabled: !model.isShownInMenuBar(snapshot.provider))
                                }
                            )
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let error = updates.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Button("Settings…") { model.openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 380, height: 420)
    }
}

private struct ProviderCard: View {
    let snapshot: UsageSnapshot
    let mode: DisplayMode
    let staleAfter: TimeInterval
    let isShownInMenuBar: Bool
    let canToggleMenuBar: Bool
    let onToggleMenuBar: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let isStale = snapshot.isStale(at: context.date, interval: staleAfter)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: snapshot.provider)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.provider.displayName).font(.headline).fixedSize()
                    Text(snapshot.plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onToggleMenuBar) {
                    Image(systemName: isShownInMenuBar ? "pin.fill" : "pin")
                        .foregroundStyle(isShownInMenuBar ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canToggleMenuBar)
                .help(isShownInMenuBar ? "Remove from menu bar" : "Show in menu bar")
                .accessibilityLabel(isShownInMenuBar ? "Remove \(snapshot.provider.displayName) from menu bar" : "Show \(snapshot.provider.displayName) in menu bar")
                let freshness = QuotaFormatting.freshnessDescription(since: snapshot.fetchedAt, now: context.date)
                if isStale {
                    Text("Stale · \(freshness)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                        .help("Last updated \(freshness)")
                } else {
                    Text("Updated \(freshness)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.label)
                        Spacer()
                        Text("\(window.percentage(for: mode))% \(mode.rawValue)")
                            .monospacedDigit()
                    }
                    QuotaBar(percentage: window.percentage(for: mode))
                    if let reset = window.resetsAt {
                        Text("Resets in \(QuotaFormatting.countdown(until: reset)) · \(QuotaFormatting.resetTimestamp(reset))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .opacity(isStale ? 0.62 : 1)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct QuotaBar: View {
    let percentage: Int

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.72))
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
