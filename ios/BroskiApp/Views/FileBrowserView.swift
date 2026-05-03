import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var bridge: BridgeService
    @State private var expandedPaths: Set<String> = []
    @State private var selectedFile: String? = nil

    var body: some View {
        Group {
            if bridge.fileTree.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No files loaded")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Load File Tree") {
                        bridge.requestFileTree(path: "~")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(bridge.fileTree) { node in
                        FileNodeRow(
                            node: node,
                            expandedPaths: $expandedPaths,
                            onSelect: { path in
                                selectedFile = path
                                bridge.requestFileContent(path: path)
                            }
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { bridge.requestFileTree(path: "~") } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { bridge.fileContent != nil },
            set: { if !$0 { bridge.fileContent = nil } }
        )) {
            if let fc = bridge.fileContent {
                FileContentView(path: fc.path, content: fc.content)
            }
        }
    }
}

struct FileNodeRow: View {
    let node: FileNode
    @Binding var expandedPaths: Set<String>
    let onSelect: (String) -> Void

    var isExpanded: Bool { expandedPaths.contains(node.path) }

    var body: some View {
        if node.type == "dir" {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { v in
                        if v { expandedPaths.insert(node.path) }
                        else { expandedPaths.remove(node.path) }
                    }
                )
            ) {
                if let children = node.children {
                    ForEach(children) { child in
                        FileNodeRow(node: child, expandedPaths: $expandedPaths, onSelect: onSelect)
                            .padding(.leading, 8)
                    }
                }
            } label: {
                Label(node.name, systemImage: isExpanded ? "folder.fill" : "folder")
                    .font(.system(.body, design: .monospaced))
            }
        } else {
            Button {
                onSelect(node.path)
            } label: {
                Label(node.name, systemImage: fileIcon(for: node.name))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":  return "swift"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "py":     return "terminal"
        case "json":   return "curlybraces"
        case "md":     return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "sh", "bash": return "terminal.fill"
        default:       return "doc"
        }
    }
}

struct FileContentView: View {
    let path: String
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
