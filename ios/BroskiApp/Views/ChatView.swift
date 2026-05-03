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
            .padding(.horizontal).padding(.vertical, 6)
            .background(Color(.systemBackground))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chatEvents.isEmpty && bridge.streamingText.isEmpty { emptyState }
                        ForEach(chatEvents) { event in
                            EventBubble(event: event, bridge: bridge) { pendingToolEvent = event }
                                .id(event.id)
                        }
                        // Streaming typewriter bubble
                        if !bridge.streamingText.isEmpty {
                            StreamingBubble(text: bridge.streamingText)
                                .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: bridge.events.count) { _ in scrollToBottom(proxy) }
                .onChange(of: bridge.streamingText) { _ in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 10) {
                TextField("Message your agent…", text: $inputText, axis: .vertical)
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
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
        .navigationTitle("Agent Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button { bridge.clearChatHistory() } label: { Image(systemName: "trash") }
                    NavigationLink {
                        FileBrowserView(bridge: bridge)
                            .onAppear { bridge.requestFileTree(path: "~") }
                    } label: { Image(systemName: "folder") }
                }
            }
        }
        .sheet(item: $pendingToolEvent) { event in
            DiffApproveView(event: event) { approved in
                if let toolId = event.toolId {
                    if approved { bridge.approveTool(toolId: toolId) }
                    else        { bridge.denyTool(toolId: toolId) }
                }
                pendingToolEvent = nil
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = chatEvents.last else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
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
            Text("Send a message to start").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

// MARK: - Streaming typewriter bubble
struct StreamingBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            Text(text)
                .foregroundStyle(Color(.label))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    // Blinking cursor
                    BlinkingCursor()
                }
        }
        .padding(.vertical, 2)
    }
}

struct BlinkingCursor: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}

// MARK: - Event bubble
struct EventBubble: View {
    let event: BroskiEvent
    let bridge: BridgeService
    var onToolTap: (() -> Void)? = nil

    var body: some View {
        switch event.type {
        case "text", "output":
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                RichMessageText(event.text ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)

        case "tool_use":
            Button(action: { onToolTap?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name ?? "tool")
                            .font(.system(.caption, design: .monospaced)).bold().foregroundStyle(.orange)
                        if let input = event.inputJson, let preview = input.split(separator: "\n").first {
                            Text(preview)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
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

// MARK: - Rich message text: markdown + syntax-highlighted code blocks
struct RichMessageText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    /// Splits text into alternating prose and code-fence segments.
    private var segments: [Segment] {
        var result: [Segment] = []
        var remaining = raw
        let fence = "```"
        while !remaining.isEmpty {
            if let open = remaining.range(of: fence) {
                let before = String(remaining[remaining.startIndex..<open.lowerBound])
                if !before.isEmpty { result.append(.prose(before)) }
                let afterOpen = remaining[open.upperBound...]
                // grab optional language hint from first line
                let firstNewline = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
                let lang = String(afterOpen[afterOpen.startIndex..<firstNewline]).trimmingCharacters(in: .whitespaces)
                let codeStart = afterOpen.index(after: firstNewline) <= afterOpen.endIndex ? afterOpen.index(after: firstNewline) : afterOpen.endIndex
                let codeBody = String(afterOpen[codeStart...])
                if let close = codeBody.range(of: fence) {
                    let code = String(codeBody[codeBody.startIndex..<close.lowerBound])
                    result.append(.code(lang: lang, body: code))
                    remaining = String(codeBody[close.upperBound...])
                } else {
                    result.append(.code(lang: lang, body: codeBody))
                    remaining = ""
                }
            } else {
                result.append(.prose(remaining))
                break
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let text):
                    if let attr = try? AttributedString(markdown: text) {
                        Text(attr).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color(.label))
                    } else {
                        Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color(.label))
                    }
                case .code(let lang, let body):
                    CodeBlock(language: lang, code: body)
                }
            }
        }
    }

    enum Segment { case prose(String); case code(lang: String, body: String) }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                if !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemBackground))

            Divider()

            // Code body
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color(.label))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}

// MARK: - Agent status chip
struct AgentStatusIndicator: View {
    let status: BridgeService.AgentStatus
    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .idle:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Idle").font(.caption).foregroundStyle(Color(.secondaryLabel))
            case .thinking:
                ProgressView().scaleEffect(0.7)
                Text("Thinking…").font(.caption).foregroundStyle(Color(.secondaryLabel))
            case .running(let tool):
                Image(systemName: "terminal").font(.caption).foregroundStyle(.orange)
                Text("Running \(tool)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
