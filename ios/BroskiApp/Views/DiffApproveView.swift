import SwiftUI

struct DiffApproveView: View {
    let event: BroskiEvent
    let onDecision: (Bool) -> Void

    var isShellTool: Bool {
        guard let name = event.name else { return false }
        return ["bash", "shell", "run_command", "computer"].contains(name.lowercased())
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Tool name
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .foregroundStyle(isShellTool ? .orange : .accentColor)
                        Text(event.name ?? "tool")
                            .font(.system(.title3, design: .monospaced)).bold()
                    }

                    // Shell warning
                    if isShellTool {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("This tool executes shell commands on your Mac. Review carefully before approving.")
                                .font(.caption).foregroundStyle(Color(.secondaryLabel))
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Input JSON as syntax-highlighted code block
                    if let input = event.inputJson {
                        CodeBlock(language: "json", code: input)
                    }

                    // Tool ID (debug)
                    if let toolId = event.toolId {
                        Text("Tool ID: \(toolId)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .padding()
            }
            .navigationTitle("Review Tool Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) { onDecision(false) } label: {
                        Label("Deny", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { onDecision(true) } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }
}
