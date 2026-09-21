import SwiftUI
import LLMitsCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Connections") {
                ForEach($model.connections) { $connection in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(connection.provider.displayName).font(.headline)
                            Picker("Credential source", selection: $connection.source) {
                                ForEach(CredentialSource.allCases, id: \.self) { source in
                                    Text(source.displayName).tag(source)
                                }
                            }
                            .labelsHidden()
                            Text("Provider authentication is not implemented yet; this enables preview data.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(connection.isConnected ? "Disconnect" : "Use preview data") {
                            model.setConnected(!connection.isConnected, provider: connection.provider)
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
}
