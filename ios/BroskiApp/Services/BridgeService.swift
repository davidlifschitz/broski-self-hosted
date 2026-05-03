import Foundation
import Network

// MARK: - Models

struct BroskiEvent: Decodable, Identifiable {
    let id: String
    let type: String
    let sessionId: String?
    let ts: Double?
    // text / output
    let text: String?
    // status
    let status: String?
    let backend: String?
    // tool_use
    let name: String?
    let inputJson: String?   // pre-serialized JSON string of tool input
    let toolId: String?

    enum CodingKeys: String, CodingKey {
        case id, type, sessionId, ts, text, status, backend, name, inputJson, toolId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type      = try c.decode(String.self, forKey: .type)
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        ts        = try? c.decode(Double.self, forKey: .ts)
        text      = try? c.decode(String.self, forKey: .text)
        status    = try? c.decode(String.self, forKey: .status)
        backend   = try? c.decode(String.self, forKey: .backend)
        name      = try? c.decode(String.self, forKey: .name)
        inputJson = try? c.decode(String.self, forKey: .inputJson)
        toolId    = try? c.decode(String.self, forKey: .toolId)
    }
}

struct EventBatch: Decodable { let events: [BroskiEvent] }

struct SessionInfo: Decodable, Identifiable {
    let id: String
    let workdir: String
    let backend: String
    let clientCount: Int
}

struct BridgeConfig: Codable {
    let url: String
    let secret: String
    let v: Int
}

// MARK: - FileNode
struct FileNode: Identifiable, Decodable {
    let id: String
    let name: String
    let type: String   // "file" | "dir"
    let path: String
    let children: [FileNode]?

    enum CodingKeys: String, CodingKey { case name, type, path, children }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name     = try c.decode(String.self, forKey: .name)
        type     = try c.decode(String.self, forKey: .type)
        path     = try c.decode(String.self, forKey: .path)
        children = try? c.decode([FileNode].self, forKey: .children)
        id       = path
    }
}

// MARK: - BridgeService
@MainActor
class BridgeService: ObservableObject {
    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var agentStatus: AgentStatus = .idle
    @Published var events: [BroskiEvent] = []
    @Published var sessions: [SessionInfo] = []
    @Published var currentSessionId: String?
    @Published var latencyMs: Double = 0
    @Published var connectionError: String?
    @Published var fileTree: [FileNode] = []
    @Published var fileContent: (path: String, content: String)? = nil

    enum AgentStatus { case idle, thinking, running(tool: String) }

    // Persistence
    private let configKey = "broski.bridgeConfig"
    var savedConfig: BridgeConfig? {
        get {
            guard let d = UserDefaults.standard.data(forKey: configKey),
                  let c = try? JSONDecoder().decode(BridgeConfig.self, from: d) else { return nil }
            return c
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(d, forKey: configKey)
            } else {
                UserDefaults.standard.removeObject(forKey: configKey)
            }
        }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var config: BridgeConfig?
    private var pingTimer: Timer?
    private var lastPingSent: Date?
    private var receiveTask: Task<Void, Never>?

    // MARK: Connect
    func connect(config: BridgeConfig) {
        self.config = config
        savedConfig = config   // persist for next launch
        _connect()
    }

    func connectIfSaved() {
        if let cfg = savedConfig { connect(config: cfg) }
    }

    private func _connect() {
        guard let cfg = config, let url = URL(string: cfg.url) else { return }
        connectionError = nil
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true
        send(["type": "auth", "secret": cfg.secret])
        receiveTask = Task { await receiveLoop() }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing() }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let ws = webSocketTask else { break }
            do {
                let msg = try await ws.receive()
                switch msg {
                case .string(let t): handleRaw(t)
                case .data(let d): if let t = String(data: d, encoding: .utf8) { handleRaw(t) }
                @unknown default: break
                }
            } catch {
                isConnected = false
                isAuthenticated = false
                agentStatus = .idle
                connectionError = error.localizedDescription
                pingTimer?.invalidate()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                _connect()
                break
            }
        }
    }

    private func handleRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let dec = JSONDecoder()

        if let batch = try? dec.decode(EventBatch.self, from: data) {
            for e in batch.events {
                // Update agent status from status events
                if e.type == "status" {
                    switch e.status {
                    case "thinking": agentStatus = .thinking
                    case "idle", "exited": agentStatus = .idle
                    default: break
                    }
                } else if e.type == "tool_use" {
                    agentStatus = .running(tool: e.name ?? "tool")
                } else if e.type == "ping" {
                    send(["type": "pong"])
                    continue
                }
                events.append(e)
            }
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String else { return }

        switch type_ {
        case "auth_ok":
            isAuthenticated = true
            listSessions()
        case "auth_error":
            connectionError = "Auth failed — wrong secret"
            savedConfig = nil   // clear bad config
        case "session_created", "session_joined":
            currentSessionId = json["sessionId"] as? String
        case "session_list":
            if let raw = try? JSONSerialization.data(withJSONObject: json["sessions"] ?? []),
               let list = try? dec.decode([SessionInfo].self, from: raw) { sessions = list }
        case "ping_ack":
            if let sent = lastPingSent {
                latencyMs = Date().timeIntervalSince(sent) * 1000
                lastPingSent = nil
            }
        case "file_tree":
            if let raw = try? JSONSerialization.data(withJSONObject: json["tree"] ?? []),
               let nodes = try? dec.decode([FileNode].self, from: raw) { fileTree = nodes }
        case "file_content":
            if let p = json["path"] as? String, let c = json["content"] as? String {
                fileContent = (path: p, content: c)
            }
        default: break
        }
    }

    // MARK: Helpers
    func send(_ dict: [String: String]) {
        guard let ws = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    func sendMessage(_ text: String) { send(["type": "message", "text": text]) }
    func createSession(workdir: String, backend: String) { send(["type": "session_create", "workdir": workdir, "backend": backend]) }
    func listSessions() { send(["type": "session_list"]) }
    func requestFileTree(path: String) { send(["type": "file_tree", "path": path]) }
    func requestFileContent(path: String) { send(["type": "file_read", "path": path]) }
    private func sendPing() { lastPingSent = Date(); send(["type": "ping"]) }

    func disconnect() {
        savedConfig = nil
        pingTimer?.invalidate()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        isAuthenticated = false
        agentStatus = .idle
    }
}
