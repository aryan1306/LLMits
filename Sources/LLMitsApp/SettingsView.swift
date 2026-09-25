import AppKit
import SwiftUI
import LLMitsCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateModel
    let onRequestUpdate: (AvailableUpdate) -> Void
    @State private var claudeCallback = ""
    @State private var drag: DragState?

    private static let rowHeight: CGFloat = 52
    private static let dragSpace = "subscriptions"

    private struct DragState {
        let provider: ProviderID
        let startIndex: Int
        var translation: CGFloat
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        "Subscriptions",
                        caption: "Drag to set the order in the popover and menu bar. Pin up to three to the menu bar."
                    ) {
                        subscriptionList
                    }

                    if let authorization = model.authorization {
                        authorizationView(authorization)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    section("General") {
                        VStack(spacing: 0) {
                            settingRow("Show quota as") {
                                Picker("Show quota as", selection: $model.preferences.displayMode) {
                                    Text("Used").tag(DisplayMode.used)
                                    Text("Remaining").tag(DisplayMode.remaining)
                                }
                                .pickerStyle(.segmented)
                            }
                            Divider()
                            settingRow("Refresh every") {
                                Picker("Refresh every", selection: $model.preferences.pollingMinutes) {
                                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                                }
                            }
                            if model.connectedProviders.contains(.antigravity) {
                                Divider()
                                settingRow("Antigravity menu bar quota") {
                                    Picker("Antigravity menu bar quota", selection: $model.preferences.antigravityPool) {
                                        ForEach(AntigravityPool.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                    }
                                }
                            }
                        }
                        .groupedCard()
                    }

                    section("Updates") {
                        updateRow
                            .groupedCard()
                    }

                    Text("Credentials and usage data stay on this Mac — no analytics, telemetry, or LLMits backend. LLMits checks GitHub for updates and only installs them with your approval. Provider integrations are unofficial and may change without notice.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .animation(.snappy(duration: 0.2), value: model.authorization)
                .animation(.snappy(duration: 0.2), value: model.connectedProviders)
            }

            Divider()
            HStack(spacing: 8) {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("LLMits", destination: URL(string: "https://github.com/aryan1306/LLMits")!)
                Text("·").foregroundStyle(.tertiary)
                Text("Brewed by").foregroundStyle(.secondary)
                Link("aryan1306", destination: URL(string: "https://github.com/aryan1306")!)
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Subscriptions

    private var subscriptionList: some View {
        let order = model.preferences.providerOrder
        return VStack(spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                subscriptionRow(provider, index: index, count: order.count)
                    .frame(height: Self.rowHeight)
                    .background {
                        if drag?.provider == provider {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                                .padding(.horizontal, -4)
                        }
                    }
                    .offset(y: offset(for: provider, at: index, count: order.count))
                    .zIndex(drag?.provider == provider ? 1 : 0)
                    .animation(
                        drag?.provider == provider ? nil : .snappy(duration: 0.2),
                        value: targetIndex(count: order.count)
                    )
                    .gesture(reorderGesture(for: provider, at: index, count: order.count))
            }
        }
        .coordinateSpace(name: Self.dragSpace)
        .background {
            // Separators stay put while rows slide over them.
            VStack(spacing: 0) {
                ForEach(0..<order.count, id: \.self) { index in
                    Color.clear
                        .frame(height: Self.rowHeight)
                        .overlay(alignment: .bottom) {
                            if index < order.count - 1 { Divider().padding(.leading, 56) }
                        }
                }
            }
        }
        .groupedCard(horizontalPadding: 12)
    }

    private func subscriptionRow(_ provider: ProviderID, index: Int, count: Int) -> some View {
        let connection = model.connections.first { $0.provider == provider } ?? ProviderConnection(provider: provider)
        let isAuthorizing = model.authorization?.provider == provider
        let isShown = model.isShownInMenuBar(provider)

        return HStack(spacing: 10) {
            DragHandle()

            ProviderIcon(provider: provider)
                .saturation(connection.isConnected ? 1 : 0)
                .opacity(connection.isConnected ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(connection.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(statusDescription(connection, isAuthorizing: isAuthorizing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if connection.isConnected {
                Button {
                    model.setMenuBarProvider(provider, enabled: !isShown)
                } label: {
                    Image(systemName: isShown ? "pin.fill" : "pin")
                        .foregroundStyle(isShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!model.canToggleMenuBar(provider))
                .help(isShown ? "Remove from menu bar" : "Show in menu bar")
                .accessibilityLabel(isShown ? "Remove \(provider.displayName) from menu bar" : "Show \(provider.displayName) in menu bar")
            }

            Group {
                if connection.isConnected {
                    Button("Disconnect") { model.disconnect(provider) }
                        .help("Stop tracking \(provider.displayName) in LLMits")
                } else {
                    Button("Connect") { model.connect(provider) }
                        .help("Connect \(provider.displayName)")
                }
            }
            .controlSize(.small)
            .frame(minWidth: 84, alignment: .trailing)
            .disabled(model.authorization != nil && !isAuthorizing)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { model.moveProvider(provider, to: index - 1) }
        .accessibilityAction(named: "Move down") { model.moveProvider(provider, to: index + 1) }
    }

    private func statusDescription(_ connection: ProviderConnection, isAuthorizing: Bool) -> String {
        if isAuthorizing { return "Signing in…" }
        guard connection.isConnected else { return "Not connected" }
        return connection.source == .cli ? "Signed in via agy CLI" : "Connected"
    }

    // MARK: - Updates

    private var updateRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check for updates")
                TimelineView(.everyMinute) { context in
                    Text(updateStatus(now: context.date))
                        .font(.caption)
                        .foregroundStyle(showsUpdateError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if updates.isChecking {
                ProgressView().controlSize(.small)
            }
            if let update = updates.availableUpdate {
                Button("Update to \(update.version)…") { onRequestUpdate(update) }
                    .disabled(updates.isInstalling)
            } else {
                Button("Check Now") { Task { await updates.checkForUpdatesManually() } }
                    .disabled(!updates.canCheck || updates.isChecking || updates.isInstalling || updates.nextManualCheck != nil)
                    .help(updates.nextManualCheck == nil ? "Check GitHub for a newer release" : "You can check again shortly")
            }
        }
        .controlSize(.small)
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }

    private var showsUpdateError: Bool {
        updates.checkErrorMessage != nil && updates.availableUpdate == nil && !updates.isChecking
    }

    private func updateStatus(now: Date) -> String {
        guard updates.canCheck else { return "Available in the packaged app." }
        if updates.isInstalling { return "Installing update…" }
        if updates.isChecking { return "Checking GitHub…" }
        if let update = updates.availableUpdate { return "LLMits \(update.version) is available." }
        if let error = updates.checkErrorMessage { return error }
        if let lastChecked = updates.lastChecked {
            return "You’re up to date. Checked \(QuotaFormatting.freshnessDescription(since: lastChecked, now: now))."
        }
        return "LLMits also checks automatically every few hours."
    }

    // MARK: - Drag to reorder

    private func targetIndex(count: Int) -> Int? {
        guard let drag else { return nil }
        let moved = drag.startIndex + Int((drag.translation / Self.rowHeight).rounded())
        return min(max(moved, 0), count - 1)
    }

    private func offset(for provider: ProviderID, at index: Int, count: Int) -> CGFloat {
        guard let drag, let target = targetIndex(count: count) else { return 0 }
        if drag.provider == provider { return drag.translation }
        if drag.startIndex < index, index <= target { return -Self.rowHeight }
        if target <= index, index < drag.startIndex { return Self.rowHeight }
        return 0
    }

    private func reorderGesture(for provider: ProviderID, at index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                let previousTarget = targetIndex(count: count)
                let start = drag?.startIndex ?? index
                // Keep the lifted row inside the card.
                let translation = min(
                    max(value.translation.height, -CGFloat(start) * Self.rowHeight),
                    CGFloat(count - 1 - start) * Self.rowHeight
                )
                drag = DragState(provider: provider, startIndex: start, translation: translation)
                if previousTarget != nil, previousTarget != targetIndex(count: count) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                guard let target = targetIndex(count: count) else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    model.moveProvider(provider, to: target)
                    drag = nil
                }
            }
    }

    // MARK: - Authorization

    @ViewBuilder
    private func authorizationView(_ authorization: AuthorizationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: authorization.provider, size: 16)
                Text("Connecting \(authorization.provider.displayName)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Cancel") { model.cancelAuthorization() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            switch authorization.phase {
            case .starting:
                progress("Starting secure sign-in…")
            case .claudeCallback:
                Text("Finish signing in in your browser, then paste the authorization code or callback URL here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Paste code or callback URL", text: $claudeCallback)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(submitClaudeCallback)
                    Button("Finish", action: submitClaudeCallback)
                        .keyboardShortcut(.defaultAction)
                        .disabled(claudeCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case let .codexCode(code):
                Text("Enter this one-time code in the browser:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .controlSize(.small)
                    Spacer()
                    progress("Waiting for approval…")
                }
            case .antigravityCLI:
                progress("Checking your agy CLI login…")
            case .exchanging:
                progress("Completing sign-in…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.connect(authorization.provider) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
        .groupedCard()
    }

    private func submitClaudeCallback() {
        let value = claudeCallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.submitClaudeCallback(value)
        claudeCallback = ""
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Layout helpers

    private func section<Content: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
                .labelsHidden()
                .fixedSize()
        }
        .frame(minHeight: 38)
    }
}

private struct DragHandle: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .frame(width: 14, height: Self.hitHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }

    private static let hitHeight: CGFloat = 32
}

private extension View {
    func groupedCard(horizontalPadding: CGFloat = 14) -> some View {
        padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}
