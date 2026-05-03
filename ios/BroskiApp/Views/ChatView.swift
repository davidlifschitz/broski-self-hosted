import SwiftUI

struct ChatView: View {
    @ObservedObject var bridge: BridgeService
    @State private var inputText = ""
    @State private var pendingToolEvent: BroskiEvent? = nil

    var chatEvents: [BroskiEvent] {
        bridge.events.filter { ["text", "output", "tool_use", "error", "result"].contains($0.type) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 6) {
                AgentStatusIndicator(status: bridge.agentStatus)
                Spacer()
                if bridge.latencyMs > 0 {
                    Text(String(format: "%.0fms", bridge.latencyMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(latencyColor)
                }
            }
            .padding(.horizontal).padding(.vertical, 6).background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chatEvents.isEmpty {
                            emptyState
                        }
                        ForEach(chatEvents) { event in
                            EventBubble(event: event) {
                                pendingToolEvent = event
                            }
                            .id(event.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatEvents.count) { _ in
                    if let last = chatEvents.last {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Message your agent...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    bridge.sendMessage(trimmed)
                    inputText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
        .navigationTitle("Agent Chat").navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing:
            NavigationLink {
                FileBrowserView(bridge: bridge)
                    .onAppear {
                        if let sid = bridge.currentSessionId {
                            // request file tree rooted at workdir
                            bridge.requestFileTree(path: "~")
                        }
                    }
            } label: {
                Image(systemName: "folder")
            }
        )
        .sheet(item: $pendingToolEvent) { event in
            DiffApproveView(event: event) { approved in
                if approved {
                    // Re-send approval signal (agent is already running; this is cosmetic for now)
                    // In a real integration wire this to a tool_response message
                    bridge.sendMessage("[approved]")
                }
                pendingToolEvent = nil
            }
        }
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bridge.isAuthenticated
            && { if case .thinking = bridge.agentStatus { return false }; return true }()
    }

    var latencyColor: Color {
        bridge.latencyMs < 10 ? .green : bridge.latencyMs < 50 ? .orange : .red
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Send a message to start")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Agent Status Indicator
struct AgentStatusIndicator: View {
    let status: BridgeService.AgentStatus
    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .idle:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Idle").font(.caption).foregroundStyle(.secondary)
            case .thinking:
                ProgressView().scaleEffect(0.7)
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            case .running(let tool):
                Image(systemName: "terminal").font(.caption).foregroundStyle(.orange)
                Text("Running \(tool)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Event Bubble
struct EventBubble: View {
    let event: BroskiEvent
    var onToolTap: (() -> Void)? = nil

    var body: some View {
        switch event.type {
        case "text", "output":
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                Text(event.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case "tool_use":
            Button(action: { onToolTap?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name ?? "tool").font(.system(.caption, design: .monospaced)).bold().foregroundStyle(.orange)
                        if let input = event.inputJson, let preview = input.split(separator: "\n").first {
                            Text(preview).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)

        case "error":
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                Text(event.text ?? "Error").font(.caption).foregroundStyle(.red)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.red.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))

        case "result":
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Done").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.green.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))

        default:
            EmptyView()
        }
    }
}
