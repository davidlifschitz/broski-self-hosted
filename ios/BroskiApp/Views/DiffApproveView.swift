import SwiftUI

/// Full-screen sheet shown when a tool_use event is tapped.
/// Displays the tool name + full JSON input and lets the user approve or deny.
struct DiffApproveView: View {
    let event: BroskiEvent
    let onDecision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var syntaxLines: [AttributedString] = []

    var toolName: String { event.name ?? "unknown" }
    var inputDisplay: String { event.inputJson ?? "{}" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Tool header
                    HStack(spacing: 10) {
                        Image(systemName: toolIconName)
                            .font(.title2)
                            .foregroundStyle(toolColor)
                            .frame(width: 36, height: 36)
                            .background(toolColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toolName)
                                .font(.headline.monospaced())
                            Text("Tool invocation")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))

                    Divider()

                    // JSON input viewer
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Input")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal).padding(.top, 12).padding(.bottom, 6)
                            Spacer()
                        }
                        Text(inputDisplay)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal)
                            .padding(.bottom, 16)
                    }

                    // If tool is bash/run/execute, show a warning
                    if ["bash", "execute", "run_command", "shell"].contains(toolName.lowercased()) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                            Text("This will execute a shell command on your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }

                    // If tool writes a file, show diff-style view
                    if ["write_file", "create_file", "edit_file", "str_replace_editor"].contains(toolName.lowercased()),
                       let content = extractFileContent() {
                        Divider().padding(.horizontal)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("File Content")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal).padding(.top, 12).padding(.bottom, 6)

                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(content)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.horizontal)
                                    .padding(.bottom, 12)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        onDecision(false)
                        dismiss()
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .tint(.red)
                }
            }
            .safeAreaInset(edge: .bottom) {
                approveBar
            }
        }
    }

    var approveBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onDecision(false)
                dismiss()
            } label: {
                Label("Deny", systemImage: "xmark.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                onDecision(true)
                dismiss()
            } label: {
                Label("Approve", systemImage: "checkmark.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: Helpers
    var toolIconName: String {
        switch toolName.lowercased() {
        case "bash", "execute", "run_command", "shell": return "terminal"
        case "write_file", "create_file", "edit_file", "str_replace_editor": return "doc.badge.plus"
        case "read_file", "view": return "doc.text"
        case "list_directory", "ls": return "folder"
        case "search", "grep": return "magnifyingglass"
        case "web_search": return "safari"
        default: return "wrench.and.screwdriver"
        }
    }

    var toolColor: Color {
        switch toolName.lowercased() {
        case "bash", "execute", "run_command", "shell": return .orange
        case "write_file", "create_file", "edit_file", "str_replace_editor": return .blue
        case "read_file", "view": return .teal
        default: return .purple
        }
    }

    func extractFileContent() -> String? {
        guard let json = inputJson as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["content"] ?? obj["new_str"] ?? obj["new_content"]).map { "\($0)" }
    }

    var inputJson: Any? { event.inputJson }
}
