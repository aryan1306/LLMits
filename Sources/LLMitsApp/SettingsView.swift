import SwiftUI
import LLMitsCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var claudeCallback = ""

    var body: some View {
        Form {
            Section("Connections") {
                ForEach($model.connections) { $connection in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.provider.displayName).font(.headline)
                                Text(connection.isConnected ? "Connected with LLMits login" : connection.provider == .claude ? "Connect your Claude subscription" : "Connect your ChatGPT subscription")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(connection.isConnected ? "Disconnect" : "Connect") {
                                if connection.isConnected { model.disconnect(connection.provider) }
                                else { model.connect(connection.provider) }
                            }
                            .disabled(model.authorization != nil && model.authorization?.provider != connection.provider)
                        }

                        if let authorization = model.authorization, authorization.provider == connection.provider {
                            authorizationView(authorization)
                        }
                    }
                }
            }

            Section("Display") {
                Picker("Quota display", selection: $model.preferences.displayMode) {
                    Text("Used").tag(DisplayMode.used)
                    Text("Remaining").tag(DisplayMode.remaining)
                }
                Picker("Polling interval", selection: $model.preferences.pollingMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Show account identity", isOn: $model.preferences.showAccountIdentity)
            }

            Section("Privacy") {
                Text("LLMits is local-only. Provider integrations are unofficial and may change without notice. No analytics, telemetry, or LLMits backend is used.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func authorizationView(_ authorization: AuthorizationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch authorization.phase {
            case .starting:
                Label("Starting secure sign-in…", systemImage: "arrow.triangle.2.circlepath")
            case .claudeCallback:
                Text("Finish signing in in your browser, then paste the authorization code or callback URL here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    TextField("Paste code or callback URL", text: $claudeCallback)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .layoutPriority(1)
                    Button("Finish") {
                        model.submitClaudeCallback(claudeCallback)
                        claudeCallback = ""
                    }
                    .fixedSize()
                    .disabled(claudeCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case let .codexCode(code):
                Text("Enter this one-time code in the browser:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(.caption).foregroundStyle(.secondary)
                }
            case .exchanging:
                HStack { ProgressView().controlSize(.small); Text("Completing sign-in…") }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                Button("Try Again") { model.connect(authorization.provider) }
            }
            Button("Cancel") { model.cancelAuthorization() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
