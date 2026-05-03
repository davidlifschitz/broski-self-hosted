import SwiftUI

struct SettingsView: View {
    @ObservedObject var bridge: BridgeService
    @Environment(\.dismiss) private var dismiss
    @State private var relayDraft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Network", systemImage: networkIcon)
                        Spacer()
                        Text(networkLabel).foregroundStyle(networkColor)
                    }
                    HStack {
                        Label("Bridge", systemImage: bridge.isAuthenticated ? "checkmark.circle" : "xmark.circle")
                        Spacer()
                        Text(bridge.isAuthenticated ? "Connected" : "Disconnected")
                            .foregroundStyle(bridge.isAuthenticated ? .green : .secondary)
                    }
                    if bridge.latencyMs > 0 {
                        HStack {
                            Label("Latency", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            Text(String(format: "%.0f ms", bridge.latencyMs))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: { Text("Status") }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When away from Wi-Fi, Broski needs a relay to reach your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Deploy the bridge to fly.io, ngrok, or Cloudflare Tunnel and paste the wss:// URL below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    TextField("wss://your-relay.fly.dev", text: $relayDraft)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save Relay URL") {
                        bridge.setRelayURL(relayDraft)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .disabled(relayDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let current = bridge.relayURL, !current.isEmpty {
                        HStack {
                            Text(current)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Clear", role: .destructive) {
                                bridge.setRelayURL("")
                                relayDraft = ""
                            }.font(.caption)
                        }
                    }
                } header: { Text("Cellular Relay") }
                .textCase(nil)

                Section {
                    Button("Disconnect & Forget Bridge", role: .destructive) {
                        bridge.disconnect()
                        dismiss()
                    }
                } header: { Text("Danger Zone") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { relayDraft = bridge.relayURL ?? "" }
        }
    }

    var networkIcon: String {
        switch bridge.networkInterface {
        case .wifi:     return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other:    return "network"
        case .none:     return "wifi.slash"
        }
    }
    var networkLabel: String {
        switch bridge.networkInterface {
        case .wifi:     return "Wi-Fi"
        case .cellular: return "Cellular"
        case .other:    return "Other"
        case .none:     return "Offline"
        }
    }
    var networkColor: Color {
        switch bridge.networkInterface {
        case .wifi:     return .green
        case .cellular: return .orange
        case .other:    return .blue
        case .none:     return .red
        }
    }
}
