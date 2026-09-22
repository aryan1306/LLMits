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
                    "No providers connected",
                    systemImage: "link.badge.plus",
                    description: Text("Open Settings to choose a credential source.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.connectedSnapshots) { snapshot in
                            ProviderCard(
                                snapshot: snapshot,
                                mode: model.preferences.displayMode,
                                staleAfter: TimeInterval(model.preferences.pollingMinutes * 60)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: snapshot.provider)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.provider.displayName).font(.headline)
                    Text(snapshot.plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Updated \(QuotaFormatting.freshnessDescription(since: snapshot.fetchedAt, now: context.date))")
                    .font(.caption2).foregroundStyle(.secondary)
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
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .opacity(snapshot.isStale(at: context.date, interval: staleAfter) ? 0.62 : 1)
        .overlay(alignment: .topTrailing) {
            if snapshot.isStale(at: context.date, interval: staleAfter) {
                Text("Stale")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .padding(8)
            }
        }
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
                        .fill(.tint)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private struct ProviderIcon: View {
    let provider: ProviderID

    var body: some View {
        if let url = Bundle.module.url(
            forResource: provider == .claude ? "claude" : "chatgpt",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    provider == .claude
                        ? Color(red: 0.85, green: 0.47, blue: 0.34)
                        : Color(red: 0.06, green: 0.64, blue: 0.50)
                )
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }
}
