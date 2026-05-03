import Foundation
import Network
import Combine

// MARK: - Models

struct BroskiEvent: Decodable, Identifiable {
    let id: String
    let type: String
    let sessionId: String?
    let ts: Double?
    let text: String?
    let status: String?
    let backend: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, type, sessionId, ts, text, status, backend, name
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
    }
}

struct EventBatch: Decodable {
    let events: [BroskiEvent]
}

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

// MARK: - Bridge Service
@MainActor
class BridgeService: ObservableObject {
    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var events: [BroskiEvent] = []
    @Published var sessions: [SessionInfo] = []
    @Published var currentSessionId: String?
    @Published var latencyMs: Double = 0
    @Published var connectionError: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var config: BridgeConfig?
    private var pingTimer: Timer?
    private var lastPingSent: Date?
    private var receiveTask: Task<Void, Never>?

    func connect(config: BridgeConfig) {
        self.config = config
        _connect()
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
                let message = try await ws.receive()
                switch message {
                case .string(let text): handleRawMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleRawMessage(text) }
                @unknown default: break
                }
            } catch {
                isConnected = false
                isAuthenticated = false
                connectionError = error.localizedDescription
                pingTimer?.invalidate()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                _connect()
                break
            }
        }
    }

    private func handleRawMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        if let batch = try? decoder.decode(EventBatch.self, from: data) {
            events.append(contentsOf: batch.events)
            for e in batch.events where e.type == "ping" { send(["type": "pong"]) }
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type_ = json["type"] as? String {
            switch type_ {
            case "auth_ok":
                isAuthenticated = true
                listSessions()
            case "auth_error":
                connectionError = "Authentication failed — wrong secret"
            case "session_created", "session_joined":
                currentSessionId = json["sessionId"] as? String
            case "session_list":
                if let raw = try? JSONSerialization.data(withJSONObject: json["sessions"] ?? []),
                   let list = try? decoder.decode([SessionInfo].self, from: raw) {
                    sessions = list
                }
            case "ping_ack":
                if let sent = lastPingSent {
                    latencyMs = Date().timeIntervalSince(sent) * 1000
                    lastPingSent = nil
                }
            default: break
            }
        }
    }

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

    private func sendPing() {
        lastPingSent = Date()
        send(["type": "ping"])
    }

    func disconnect() {
        pingTimer?.invalidate()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        isAuthenticated = false
    }
}
