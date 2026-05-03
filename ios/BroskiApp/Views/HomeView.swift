import SwiftUI

struct HomeView: View {
    @StateObject var bridge = BridgeService()
    @StateObject var mdns = MDNSDiscovery()
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var showSettings = false
    @State private var manualURL = ""
    @State private var manualSecret = ""

    var body: some View {
        NavigationStack {
            Group {
                if bridge.isAuthenticated {
                    SessionListView(bridge: bridge)
                } else {
                    pairingScreen
                }
            }
            .navigationTitle("Broski")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .onAppear {
            mdns.start()
            bridge.connectIfSaved()
        }
        .onDisappear { mdns.stop() }
        .sheet(isPresented: $showSettings) {
            SettingsView(bridge: bridge)
        }
    }

    var pairingScreen: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 60)).foregroundStyle(.tint)
                    Text("Connect to Bridge").font(.largeTitle.bold())
                    Text("Run `node bridge.js` on your Mac, then scan the QR code.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                .padding(.top, 40)

                if bridge.isOnCellular {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You're on cellular").font(.subheadline.bold())
                            Text("Connect to Wi-Fi or set a relay URL in Settings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Settings") { showSettings = true }.font(.caption.bold())
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                Button { showQRScanner = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)

                if !mdns.discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Found on Local Network").font(.headline).padding(.horizontal)
                        ForEach(mdns.discovered) { b in
                            Button {
                                manualURL = b.wsURL
                                showManualEntry = true
                            } label: {
                                HStack {
                                    Image(systemName: "wifi")
                                    VStack(alignment: .leading) {
                                        Text(b.name).font(.subheadline.bold())
                                        Text(b.wsURL).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding().background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain).padding(.horizontal)
                        }
                    }
                }

                Button("Enter URL Manually") { showManualEntry = true }
                    .font(.subheadline).foregroundStyle(.secondary)

                if let err = bridge.connectionError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .padding(.horizontal).multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScanSheet { payload in showQRScanner = false; handleQR(payload) }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet(url: $manualURL, secret: $manualSecret) {
                showManualEntry = false; connectManual()
            }
        }
    }

    func handleQR(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(BridgeConfig.self, from: data) else {
            bridge.connectionError = "Invalid QR code"; return
        }
        bridge.connect(config: cfg)
    }

    func connectManual() {
        bridge.connect(config: BridgeConfig(url: manualURL, secret: manualSecret, v: 1))
    }
}

struct QRScanSheet: View {
    let onScan: (String) -> Void
    var body: some View {
        NavigationStack {
            QRScannerView(onScan: onScan).ignoresSafeArea()
                .navigationTitle("Scan QR Code").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ManualEntrySheet: View {
    @Binding var url: String
    @Binding var secret: String
    let onConnect: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge URL") {
                    TextField("ws://192.168.1.x:7337", text: $url)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Secret") {
                    SecureField("Paste from terminal", text: $secret)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Manual Connect").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: onConnect).disabled(url.isEmpty || secret.isEmpty)
                }
            }
        }
    }
}
