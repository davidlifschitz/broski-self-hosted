import SwiftUI

struct ChatView: View {
    @ObservedObject var bridge: BridgeService
    @State private var inputText = ""

    var chatEvents: [BroskiEvent] {
        bridge.events.filter { ["text", "output", "tool_use", "error"].contains($0.type) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(bridge.isAuthenticated ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(bridge.isAuthenticated ? "Connected" : "Connecting...")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if bridge.latencyMs > 0 {
                    Text(String(format: "%.0fms", bridge.latencyMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(bridge.latencyMs < 10 ? .green : bridge.latencyMs < 50 ? .orange : .red)
                }
            }
            .padding(.horizontal).padding(.vertical, 6).background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chatEvents) { event in
                            EventBubble(event: event).id(event.id)
                        }
                    }.padding()
                }
                .onChange(of: chatEvents.count) { _ in
                    if let last = chatEvents.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
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
                    guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    bridge.sendMessage(inputText)
                    inputText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(inputText.isEmpty ? Color.secondary : Color.accentColor)
                }
                .disabled(inputText.isEmpty || !bridge.isAuthenticated)
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
        .navigationTitle("Agent Chat").navigationBarTitleDisplayMode(.inline)
    }
}

struct EventBubble: View {
    let event: BroskiEvent
    var body: some View {
        Group {
            switch event.type {
            case "text", "output":
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    Text(event.text ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.padding(.vertical, 4)
            case "tool_use":
                HStack(spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(.orange)
                    Text(event.name ?? "tool").font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
            case "error":
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                    Text(event.text ?? "Error").font(.caption).foregroundStyle(.red)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.red.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
            default: EmptyView()
            }
        }
    }
}
