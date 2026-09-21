import SwiftUI
import LLMitsCore

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("LLMits").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.manualRefresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)
                .help("Refresh quotas")
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
                            ProviderCard(snapshot: snapshot, mode: model.preferences.displayMode)
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.provider.displayName).font(.headline)
                Text(snapshot.plan).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Updated \(snapshot.fetchedAt, style: .relative)")
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
                    ProgressView(value: Double(window.percentage(for: mode)), total: 100)
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
    }
}
