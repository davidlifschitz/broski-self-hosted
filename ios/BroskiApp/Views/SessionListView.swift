import SwiftUI

struct SessionListView: View {
    @ObservedObject var bridge: BridgeService
    @State private var showNewSession = false
    @State private var newWorkdir = "~"
    @State private var selectedBackend = "claude"
    let backends = ["claude", "opencode", "custom"]

    var body: some View {
        List {
            Section {
                ForEach(bridge.sessions) { session in
                    NavigationLink {
                        ChatView(bridge: bridge)
                            .onAppear { bridge.send(["type": "session_join", "sessionId": session.id]) }
                    } label: {
                        SessionRow(session: session)
                    }
                }
            } header: {
                HStack {
                    Text("Active Sessions")
                    Spacer()
                    Button { bridge.listSessions() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNewSession = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NavigationStack {
                Form {
                    Section("Working Directory") {
                        TextField("~/projects/myapp", text: $newWorkdir)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    Section("Backend") {
                        Picker("Backend", selection: $selectedBackend) {
                            ForEach(backends, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }
                .navigationTitle("New Session")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") {
                            bridge.createSession(workdir: newWorkdir, backend: selectedBackend)
                            showNewSession = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showNewSession = false }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(URL(fileURLWithPath: session.workdir).lastPathComponent).font(.headline)
            HStack {
                Label(session.backend, systemImage: "cpu")
                Spacer()
                Label("\(session.clientCount) client\(session.clientCount == 1 ? "" : "s")", systemImage: "iphone")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
