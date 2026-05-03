# Broski Bridge

Node.js WebSocket server. Runs on your Mac and bridges the iOS app to your AI agent.

## Setup

```bash
npm install
node bridge.js
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | 7337 | WebSocket port |
| `BACKEND` | claude | `claude` / `opencode` / `custom` |
| `BROSKI_SECRET` | (random) | Auth secret shown in QR |
| `CUSTOM_CMD` | - | Shell command for custom backend |

## RTT-Adaptive Batching

The server measures round-trip time via ping/pong every 2 seconds and adjusts the event batch flush interval to `clamp(8ms, RTT × 0.5, 100ms)`. On local Wi-Fi (~2ms RTT) this gives ~1ms batching. On cellular (~40ms RTT) it coalesces to ~20ms to prevent jitter.
