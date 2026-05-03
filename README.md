# Broski Self-Hosted

A self-hosted replacement for [broskiapp.com](https://broskiapp.com) — direct WebSocket bridge between your iPhone and Mac AI coding agents.

## Architecture

```
iPhone (SwiftUI) ──── WebSocket ──── Mac Bridge (Node.js) ──── Claude Code / OpenCode / Custom Agent
```

- **Zero cloud** — direct local WebSocket, no relay server
- **RTT-adaptive batching** — flushes at `clamp(8ms, RTT×0.5, 100ms)`
- **mDNS auto-discovery** — iPhone finds bridge automatically on same Wi-Fi
- **Native iOS rendering** — SwiftUI + AVFoundation, no WKWebView
- **Multi-backend** — Claude Code, OpenCode, or any custom agent

## Quick Start

### Mac Bridge

```bash
cd bridge
npm install
node bridge.js
# Scan the QR code with the iOS app
```

### Backend options

```bash
BACKEND=claude node bridge.js       # Claude Code (default)
BACKEND=opencode node bridge.js     # OpenCode
BACKEND=custom CUSTOM_CMD="python my_agent.py" node bridge.js
```

### iOS App

Open `ios/BroskiApp.xcodeproj` in Xcode 15+, set your Team, build to device (iOS 16+).

Required `Info.plist` keys:
```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan the bridge QR code</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover your Broski bridge on Wi-Fi</string>
<key>NSBonjourServices</key>
<array><string>_broski._tcp</string></array>
```

## Remote Access (Wi-Fi → Cellular)

Install [Tailscale](https://tailscale.com) on both your Mac and iPhone. The bridge URL becomes `ws://100.x.x.x:7337` — works identically over cellular.

## WebSocket Protocol

### Client → Server
```json
{ "type": "auth", "secret": "..." }
{ "type": "session_create", "workdir": "/path", "backend": "claude" }
{ "type": "session_join", "sessionId": "uuid" }
{ "type": "message", "text": "user prompt" }
{ "type": "file_tree", "path": "/path" }
{ "type": "file_read", "path": "/path/file.py" }
{ "type": "ping" }
```

### Server → Client (RTT-batched)
```json
{ "events": [
  { "type": "text", "sessionId": "...", "text": "...", "ts": 1234 },
  { "type": "tool_use", "name": "bash", "input": { "command": "ls" } },
  { "type": "status", "status": "ready", "backend": "claude" }
]}
```

## License

MIT
