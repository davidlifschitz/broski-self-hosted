# Broski Self-Hosted

A self-hosted replacement for [broskiapp.com](https://broskiapp.com) — direct WebSocket bridge between your iPhone and Mac AI coding agents.

## Architecture

```
iPhone (SwiftUI) ──── WebSocket ──── Mac Bridge (Node.js) ──── Claude Code / OpenCode / Custom Agent
```

- **Zero cloud** — direct local WebSocket on Wi-Fi for minimum latency
- **RTT-adaptive batching** — flushes at `clamp(8ms, RTT×0.5, 100ms)`
- **mDNS auto-discovery** — iPhone finds bridge automatically on same Wi-Fi
- **Native iOS rendering** — SwiftUI + AVFoundation, no WKWebView
- **Multi-backend** — Claude Code, OpenCode, or any custom agent
- **Cellular relay fallback** — optional `wss://` relay URL for away-from-home access

## Quick Start

### Mac Bridge

```bash
cd bridge
cp .env.example .env
npm install
npm start
# Scan the QR code with the iOS app
```

### Backend options

```bash
BACKEND=claude npm start
BACKEND=opencode npm start
BACKEND=custom CUSTOM_CMD="python my_agent.py" npm start
```

### iOS App

Open the iOS project/package in Xcode 15+, set your Team, and build to a physical device (iOS 16+).

Required `Info.plist` keys:
```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan the bridge QR code</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover your Broski bridge on Wi-Fi</string>
<key>NSBonjourServices</key>
<array><string>_broski._tcp</string></array>
```

## Relay Deploy Guide

The fastest production-ish path is Fly.io because it supports long-lived WebSockets well.

### 1) Install Fly CLI

```bash
brew install flyctl
fly auth login
```

### 2) Create `fly.toml`

```toml
app = "broski-relay"
primary_region = "ewr"

[build]

[http_service]
  internal_port = 7337
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1

[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory_mb = 256
```

### 3) Add a Dockerfile in `bridge/`

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY . .
EXPOSE 7337
CMD ["node", "bridge.js"]
```

### 4) Set secrets and deploy

```bash
cd bridge
fly launch --no-deploy
fly secrets set BROSKI_SECRET=supersecret BACKEND=claude
fly deploy
```

### 5) Use the relay in iOS

Paste your Fly hostname into Settings as:

```text
wss://broski-relay.fly.dev
```

When the phone leaves Wi-Fi, the app automatically switches from the local `ws://192.168.x.x:7337` bridge to the relay URL if configured.

## Alternative Relay Options

- **Tailscale** — easiest private setup, great if both Mac and iPhone can run Tailscale
- **ngrok** — fastest demo tunnel, but less ideal for persistent daily use
- **Cloudflare Tunnel** — solid if you already use Cloudflare

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

## Remaining TODOs

- Add `AppIcon.appiconset`
- Add syntax-highlighted code fences in chat
- Add streaming token-by-token typewriter rendering
- Harden relay auth / TLS / rate limits for public deployment

## License

MIT
