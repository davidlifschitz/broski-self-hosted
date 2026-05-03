#!/usr/bin/env node
/**
 * Broski Bridge Server
 * Self-hosted WebSocket bridge for AI coding agents
 * Supports: Claude Code, OpenCode, custom agents
 */

const { WebSocketServer, WebSocket } = require('ws');
const { execSync, spawn } = require('child_process');
const os = require('os');
const crypto = require('crypto');
const qrcode = require('qrcode-terminal');
const { v4: uuidv4 } = require('uuid');

// ── Config ────────────────────────────────────────────────────────────────────
const CONFIG = {
  port: process.env.PORT || 7337,
  secret: process.env.BROSKI_SECRET || crypto.randomBytes(16).toString('hex'),
  backend: process.env.BACKEND || 'claude', // claude | opencode | custom
  customCommand: process.env.CUSTOM_CMD || null,
  rttSampleWindow: 5,
  batchIntervalMin: 8,
  batchIntervalMax: 100,
};

// ── RTT-Adaptive Batcher ──────────────────────────────────────────────────────
class RTTAdaptiveBatcher {
  constructor(flushFn) {
    this.flushFn = flushFn;
    this.queue = [];
    this.rttSamples = [];
    this.currentInterval = 16;
    this.timer = null;
    this.lastPingSent = null;
  }

  recordPing() { this.lastPingSent = Date.now(); }

  recordPong() {
    if (!this.lastPingSent) return;
    const rtt = Date.now() - this.lastPingSent;
    this.rttSamples.push(rtt);
    if (this.rttSamples.length > CONFIG.rttSampleWindow) this.rttSamples.shift();
    this._adaptInterval();
  }

  _adaptInterval() {
    const avgRtt = this.rttSamples.reduce((a, b) => a + b, 0) / this.rttSamples.length;
    const target = Math.max(CONFIG.batchIntervalMin, Math.min(CONFIG.batchIntervalMax, avgRtt * 0.5));
    this.currentInterval = Math.round(target);
  }

  push(event) {
    this.queue.push(event);
    if (!this.timer) this.timer = setTimeout(() => this._flush(), this.currentInterval);
  }

  _flush() {
    this.timer = null;
    if (this.queue.length === 0) return;
    const batch = this.queue.splice(0);
    this.flushFn(batch);
  }

  destroy() { if (this.timer) clearTimeout(this.timer); }
}

// ── Backend Adapters ──────────────────────────────────────────────────────────
class BackendAdapter {
  constructor(sessionId, onEvent) {
    this.sessionId = sessionId;
    this.onEvent = onEvent;
    this.proc = null;
  }
  start(workdir) { throw new Error('Not implemented'); }
  send(text) { throw new Error('Not implemented'); }
  stop() { if (this.proc) { this.proc.kill(); this.proc = null; } }
  _emit(type, data) { this.onEvent({ type, sessionId: this.sessionId, ts: Date.now(), ...data }); }
}

class ClaudeCodeAdapter extends BackendAdapter {
  start(workdir) {
    this._emit('status', { status: 'starting', backend: 'claude' });
    this.proc = spawn('claude', ['--output-format', 'stream-json', '--verbose'], {
      cwd: workdir,
      env: { ...process.env, FORCE_COLOR: '0' },
    });
    this.proc.stdout.on('data', (chunk) => {
      const lines = chunk.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        try { this._handleClaudeMessage(JSON.parse(line)); }
        catch { this._emit('output', { text: line }); }
      }
    });
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (code) => this._emit('status', { status: 'exited', code }));
    this._emit('status', { status: 'ready', backend: 'claude' });
  }
  _handleClaudeMessage(msg) {
    switch (msg.type) {
      case 'assistant':
        if (msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') this._emit('text', { text: block.text });
            else if (block.type === 'tool_use') this._emit('tool_use', { name: block.name, input: block.input, id: block.id });
          }
        }
        break;
      case 'result': this._emit('result', { result: msg }); break;
      default: this._emit('raw', { data: msg });
    }
  }
  send(text) { if (this.proc?.stdin) this.proc.stdin.write(text + '\n'); }
}

class OpenCodeAdapter extends BackendAdapter {
  start(workdir) {
    this._emit('status', { status: 'starting', backend: 'opencode' });
    this.proc = spawn('opencode', ['run', '--json'], { cwd: workdir });
    this.proc.stdout.on('data', (chunk) => {
      const lines = chunk.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        try { this._emit('raw', { data: JSON.parse(line) }); }
        catch { this._emit('output', { text: line }); }
      }
    });
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (code) => this._emit('status', { status: 'exited', code }));
    this._emit('status', { status: 'ready', backend: 'opencode' });
  }
  send(text) { if (this.proc?.stdin) this.proc.stdin.write(text + '\n'); }
}

class CustomAdapter extends BackendAdapter {
  start(workdir) {
    if (!CONFIG.customCommand) { this._emit('error', { text: 'No CUSTOM_CMD set' }); return; }
    this._emit('status', { status: 'starting', backend: 'custom' });
    const [cmd, ...args] = CONFIG.customCommand.split(' ');
    this.proc = spawn(cmd, args, { cwd: workdir, shell: true });
    this.proc.stdout.on('data', (d) => this._emit('output', { text: d.toString() }));
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (code) => this._emit('status', { status: 'exited', code }));
    this._emit('status', { status: 'ready', backend: 'custom' });
  }
  send(text) { if (this.proc?.stdin) this.proc.stdin.write(text + '\n'); }
}

function createAdapter(backend, sessionId, onEvent) {
  switch (backend) {
    case 'claude':   return new ClaudeCodeAdapter(sessionId, onEvent);
    case 'opencode': return new OpenCodeAdapter(sessionId, onEvent);
    case 'custom':   return new CustomAdapter(sessionId, onEvent);
    default:         return new ClaudeCodeAdapter(sessionId, onEvent);
  }
}

// ── Session Manager ───────────────────────────────────────────────────────────
class SessionManager {
  constructor() { this.sessions = new Map(); }

  create(workdir, backend, onEvent) {
    const sessionId = uuidv4();
    const adapter = createAdapter(backend, sessionId, onEvent);
    this.sessions.set(sessionId, { adapter, workdir, backend, clients: new Set() });
    adapter.start(workdir);
    return sessionId;
  }

  get(sessionId) { return this.sessions.get(sessionId); }

  list() {
    return Array.from(this.sessions.entries()).map(([id, s]) => ({
      id, workdir: s.workdir, backend: s.backend, clientCount: s.clients.size,
    }));
  }

  addClient(sessionId, ws) { const s = this.sessions.get(sessionId); if (s) s.clients.add(ws); }
  removeClient(sessionId, ws) { const s = this.sessions.get(sessionId); if (s) s.clients.delete(ws); }
  send(sessionId, text) { const s = this.sessions.get(sessionId); if (s) s.adapter.send(text); }
  destroy(sessionId) { const s = this.sessions.get(sessionId); if (s) { s.adapter.stop(); this.sessions.delete(sessionId); } }
}

// ── WebSocket Server ──────────────────────────────────────────────────────────
const sessions = new SessionManager();
const wss = new WebSocketServer({ port: CONFIG.port });
const clientBatchers = new Map();

wss.on('connection', (ws, req) => {
  console.log(`[bridge] client connected from ${req.socket.remoteAddress}`);

  const batcher = new RTTAdaptiveBatcher((batch) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ events: batch }));
  });
  clientBatchers.set(ws, batcher);

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.type === 'auth') {
      if (msg.secret !== CONFIG.secret) {
        ws.send(JSON.stringify({ type: 'auth_error', message: 'Invalid secret' }));
        ws.close();
        return;
      }
      ws.authenticated = true;
      ws.send(JSON.stringify({ type: 'auth_ok', bridgeVersion: '1.0.0' }));
      return;
    }

    if (!ws.authenticated) { ws.send(JSON.stringify({ type: 'error', message: 'Not authenticated' })); return; }

    if (msg.type === 'pong') { batcher.recordPong(); return; }

    switch (msg.type) {
      case 'session_create': {
        const workdir = msg.workdir || process.cwd();
        const backend = msg.backend || CONFIG.backend;
        const sessionId = sessions.create(workdir, backend, (event) => {
          const s = sessions.get(sessionId);
          if (!s) return;
          for (const client of s.clients) {
            const cb = clientBatchers.get(client);
            if (cb) cb.push(event);
          }
        });
        sessions.addClient(sessionId, ws);
        ws.sessionId = sessionId;
        ws.send(JSON.stringify({ type: 'session_created', sessionId }));
        break;
      }
      case 'session_join': {
        const s = sessions.get(msg.sessionId);
        if (!s) { ws.send(JSON.stringify({ type: 'error', message: 'Session not found' })); return; }
        sessions.addClient(msg.sessionId, ws);
        ws.sessionId = msg.sessionId;
        ws.send(JSON.stringify({ type: 'session_joined', sessionId: msg.sessionId }));
        break;
      }
      case 'session_list':
        ws.send(JSON.stringify({ type: 'session_list', sessions: sessions.list() }));
        break;
      case 'message':
        if (!ws.sessionId) { ws.send(JSON.stringify({ type: 'error', message: 'No active session' })); return; }
        sessions.send(ws.sessionId, msg.text);
        break;
      case 'ping':
        batcher.recordPing();
        ws.send(JSON.stringify({ type: 'ping_ack', ts: Date.now() }));
        break;
      case 'file_tree': {
        const dir = msg.path || process.cwd();
        try { ws.send(JSON.stringify({ type: 'file_tree', tree: buildFileTree(dir, 3) })); }
        catch (e) { ws.send(JSON.stringify({ type: 'error', message: e.message })); }
        break;
      }
      case 'file_read': {
        try {
          const fs = require('fs');
          ws.send(JSON.stringify({ type: 'file_content', path: msg.path, content: fs.readFileSync(msg.path, 'utf8') }));
        } catch (e) { ws.send(JSON.stringify({ type: 'error', message: e.message })); }
        break;
      }
    }
  });

  ws.on('close', () => {
    if (ws.sessionId) sessions.removeClient(ws.sessionId, ws);
    const b = clientBatchers.get(ws);
    if (b) { b.destroy(); clientBatchers.delete(ws); }
    console.log('[bridge] client disconnected');
  });

  const pingInterval = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
      const b = clientBatchers.get(ws);
      if (b) b.recordPing();
      ws.send(JSON.stringify({ type: 'ping', ts: Date.now() }));
    } else { clearInterval(pingInterval); }
  }, 2000);
});

// ── File Tree ─────────────────────────────────────────────────────────────────
const fs = require('fs');
const path = require('path');

function buildFileTree(dir, depth) {
  if (depth === 0) return null;
  const items = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const entry of entries) {
    if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      items.push({ name: entry.name, type: 'dir', path: fullPath, children: buildFileTree(fullPath, depth - 1) });
    } else {
      items.push({ name: entry.name, type: 'file', path: fullPath });
    }
  }
  return items;
}

// ── mDNS Advertisement ────────────────────────────────────────────────────────
function advertiseMDNS() {
  try {
    const mdns = require('mdns-js');
    const service = mdns.createAdvertisement(mdns.tcp('broski'), CONFIG.port, {
      name: `Broski Bridge @ ${os.hostname()}`,
    });
    service.start();
    console.log('[bridge] mDNS advertisement started → _broski._tcp.local');
  } catch (e) {
    console.log('[bridge] mDNS unavailable:', e.message);
  }
}

// ── Startup ───────────────────────────────────────────────────────────────────
function getLocalIP() {
  const ifaces = os.networkInterfaces();
  for (const iface of Object.values(ifaces)) {
    for (const addr of iface) {
      if (addr.family === 'IPv4' && !addr.internal) return addr.address;
    }
  }
  return '127.0.0.1';
}

const localIP = getLocalIP();
const wsURL = `ws://${localIP}:${CONFIG.port}`;
const pairingPayload = JSON.stringify({ url: wsURL, secret: CONFIG.secret, v: 1 });

console.log('\n╔════════════════════════════════════════╗');
console.log('║       🤙 Broski Bridge Server          ║');
console.log('╚════════════════════════════════════════╝\n');
console.log(`  Listening on : ${wsURL}`);
console.log(`  Backend      : ${CONFIG.backend}`);
console.log(`  Secret       : ${CONFIG.secret}\n`);
console.log('  Scan this QR code with the Broski iOS app:\n');

qrcode.generate(pairingPayload, { small: true });

console.log(`\n  Or paste: broski://pair?url=${encodeURIComponent(wsURL)}&secret=${CONFIG.secret}\n`);

advertiseMDNS();
console.log('[bridge] ready — waiting for connections...\n');
