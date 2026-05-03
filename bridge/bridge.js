#!/usr/bin/env node
/**
 * Broski Bridge Server v1.1.0
 * Fixes: Claude Code adapter (per-message invocation + history threading)
 */

const { WebSocketServer, WebSocket } = require('ws');
const { spawn } = require('child_process');
const os = require('os');
const crypto = require('crypto');
const qrcode = require('qrcode-terminal');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');

const CONFIG = {
  port: process.env.PORT || 7337,
  secret: process.env.BROSKI_SECRET || crypto.randomBytes(16).toString('hex'),
  backend: process.env.BACKEND || 'claude',
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
    const avg = this.rttSamples.reduce((a, b) => a + b, 0) / this.rttSamples.length;
    this.currentInterval = Math.round(Math.max(CONFIG.batchIntervalMin, Math.min(CONFIG.batchIntervalMax, avg * 0.5)));
    this.lastPingSent = null;
  }
  push(event) {
    this.queue.push(event);
    if (!this.timer) this.timer = setTimeout(() => this._flush(), this.currentInterval);
  }
  _flush() {
    this.timer = null;
    if (!this.queue.length) return;
    this.flushFn(this.queue.splice(0));
  }
  destroy() { if (this.timer) clearTimeout(this.timer); }
}

// ── Backend Adapters ──────────────────────────────────────────────────────────
class BackendAdapter {
  constructor(sessionId, onEvent) {
    this.sessionId = sessionId;
    this.onEvent = onEvent;
    this.history = []; // { role: 'user'|'assistant', content: string }
  }
  send(text) { throw new Error('Not implemented'); }
  stop() {}
  _emit(type, data) { this.onEvent({ type, sessionId: this.sessionId, ts: Date.now(), id: uuidv4(), ...data }); }
}

/**
 * FIX: Claude Code is a one-shot CLI tool, not a persistent REPL.
 * Correct usage: `claude -p "<prompt>" --output-format stream-json`
 * We maintain history ourselves and pass the full conversation via
 * a system prompt + history file trick on each invocation.
 */
class ClaudeCodeAdapter extends BackendAdapter {
  constructor(sessionId, onEvent, workdir) {
    super(sessionId, onEvent);
    this.workdir = workdir;
    this.running = false;
  }

  send(userText) {
    if (this.running) {
      this._emit('error', { text: 'Agent is busy — please wait.' });
      return;
    }
    this.history.push({ role: 'user', content: userText });
    this._emit('status', { status: 'thinking', backend: 'claude' });
    this.running = true;

    // Build full prompt: inject prior turns as context
    const historyContext = this.history.slice(0, -1).map(h =>
      `${h.role === 'user' ? 'Human' : 'Assistant'}: ${h.content}`
    ).join('\n');

    const fullPrompt = historyContext
      ? `Previous conversation:\n${historyContext}\n\nHuman: ${userText}`
      : userText;

    const args = [
      '-p', fullPrompt,
      '--output-format', 'stream-json',
      '--verbose',
      '--no-interactive',
    ];

    const proc = spawn('claude', args, {
      cwd: this.workdir,
      env: { ...process.env, FORCE_COLOR: '0' },
    });

    let assistantText = '';

    proc.stdout.on('data', (chunk) => {
      const lines = chunk.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        try {
          const msg = JSON.parse(line);
          this._handleClaudeMessage(msg, (text) => { assistantText += text; });
        } catch {
          this._emit('output', { text: line });
        }
      }
    });

    proc.stderr.on('data', (d) => {
      const text = d.toString().trim();
      if (text) this._emit('error', { text });
    });

    proc.on('exit', (code) => {
      this.running = false;
      if (assistantText) {
        this.history.push({ role: 'assistant', content: assistantText });
      }
      this._emit('status', { status: 'idle', backend: 'claude', exitCode: code });
    });
  }

  _handleClaudeMessage(msg, onText) {
    switch (msg.type) {
      case 'assistant':
        if (msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') {
              this._emit('text', { text: block.text });
              onText(block.text);
            } else if (block.type === 'tool_use') {
              this._emit('tool_use', {
                name: block.name,
                inputJson: JSON.stringify(block.input, null, 2),
                toolId: block.id,
              });
            }
          }
        }
        break;
      case 'result':
        this._emit('result', { subtype: msg.subtype, durationMs: msg.duration_ms });
        break;
      case 'system':
        // session init info — suppress unless useful
        break;
      default:
        this._emit('raw', { data: msg });
    }
  }

  stop() {
    // no persistent proc to kill — each invocation is self-contained
    this.running = false;
  }
}

class OpenCodeAdapter extends BackendAdapter {
  constructor(sessionId, onEvent, workdir) {
    super(sessionId, onEvent);
    this.workdir = workdir;
    this.proc = null;
  }
  start() {
    this._emit('status', { status: 'starting', backend: 'opencode' });
    this.proc = spawn('opencode', ['run', '--json'], { cwd: this.workdir });
    this.proc.stdout.on('data', (chunk) => {
      chunk.toString().split('\n').filter(Boolean).forEach(line => {
        try { this._emit('raw', { data: JSON.parse(line) }); }
        catch { this._emit('output', { text: line }); }
      });
    });
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (code) => this._emit('status', { status: 'exited', code }));
    this._emit('status', { status: 'idle', backend: 'opencode' });
  }
  send(text) { if (this.proc?.stdin) this.proc.stdin.write(text + '\n'); }
  stop() { this.proc?.kill(); }
}

class CustomAdapter extends BackendAdapter {
  constructor(sessionId, onEvent, workdir) {
    super(sessionId, onEvent);
    this.workdir = workdir;
    this.proc = null;
  }
  start() {
    if (!CONFIG.customCommand) { this._emit('error', { text: 'No CUSTOM_CMD set' }); return; }
    const [cmd, ...args] = CONFIG.customCommand.split(' ');
    this.proc = spawn(cmd, args, { cwd: this.workdir, shell: true });
    this.proc.stdout.on('data', (d) => this._emit('output', { text: d.toString() }));
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (code) => this._emit('status', { status: 'exited', code }));
    this._emit('status', { status: 'idle', backend: 'custom' });
  }
  send(text) { if (this.proc?.stdin) this.proc.stdin.write(text + '\n'); }
  stop() { this.proc?.kill(); }
}

function createAdapter(backend, sessionId, onEvent, workdir) {
  const a = (() => {
    switch (backend) {
      case 'claude':   return new ClaudeCodeAdapter(sessionId, onEvent, workdir);
      case 'opencode': return new OpenCodeAdapter(sessionId, onEvent, workdir);
      case 'custom':   return new CustomAdapter(sessionId, onEvent, workdir);
      default:         return new ClaudeCodeAdapter(sessionId, onEvent, workdir);
    }
  })();
  // OpenCode and Custom have persistent processes; start them now
  if (a.start) a.start();
  return a;
}

// ── Session Manager ───────────────────────────────────────────────────────────
class SessionManager {
  constructor() { this.sessions = new Map(); }
  create(workdir, backend, onEvent) {
    const sessionId = uuidv4();
    const adapter = createAdapter(backend, sessionId, onEvent, workdir);
    this.sessions.set(sessionId, { adapter, workdir, backend, clients: new Set() });
    return sessionId;
  }
  get(id) { return this.sessions.get(id); }
  list() {
    return [...this.sessions.entries()].map(([id, s]) => ({
      id, workdir: s.workdir, backend: s.backend, clientCount: s.clients.size,
    }));
  }
  addClient(id, ws) { this.sessions.get(id)?.clients.add(ws); }
  removeClient(id, ws) { this.sessions.get(id)?.clients.delete(ws); }
  send(id, text) { this.sessions.get(id)?.adapter.send(text); }
  destroy(id) { const s = this.sessions.get(id); if (s) { s.adapter.stop(); this.sessions.delete(id); } }
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
        ws.close(); return;
      }
      ws.authenticated = true;
      ws.send(JSON.stringify({ type: 'auth_ok', bridgeVersion: '1.1.0' }));
      return;
    }
    if (!ws.authenticated) { ws.send(JSON.stringify({ type: 'error', message: 'Not authenticated' })); return; }
    if (msg.type === 'pong') { batcher.recordPong(); return; }

    switch (msg.type) {
      case 'session_create': {
        const workdir = msg.workdir || process.cwd();
        const backend = msg.backend || CONFIG.backend;
        const sid = sessions.create(workdir, backend, (event) => {
          const s = sessions.get(sid);
          if (!s) return;
          s.clients.forEach(c => clientBatchers.get(c)?.push(event));
        });
        sessions.addClient(sid, ws);
        ws.sessionId = sid;
        ws.send(JSON.stringify({ type: 'session_created', sessionId: sid }));
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
        ws.send(JSON.stringify({ type: 'session_list', sessions: sessions.list() })); break;
      case 'message':
        if (!ws.sessionId) { ws.send(JSON.stringify({ type: 'error', message: 'No active session' })); return; }
        sessions.send(ws.sessionId, msg.text); break;
      case 'ping':
        batcher.recordPing();
        ws.send(JSON.stringify({ type: 'ping_ack', ts: Date.now() })); break;
      case 'file_tree': {
        const dir = msg.path || process.cwd();
        try { ws.send(JSON.stringify({ type: 'file_tree', path: dir, tree: buildFileTree(dir, 4) })); }
        catch (e) { ws.send(JSON.stringify({ type: 'error', message: e.message })); }
        break;
      }
      case 'file_read': {
        try { ws.send(JSON.stringify({ type: 'file_content', path: msg.path, content: fs.readFileSync(msg.path, 'utf8') })); }
        catch (e) { ws.send(JSON.stringify({ type: 'error', message: e.message })); }
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
      batcher.recordPing();
      ws.send(JSON.stringify({ type: 'ping', ts: Date.now() }));
    } else { clearInterval(pingInterval); }
  }, 2000);
});

// ── File Tree ─────────────────────────────────────────────────────────────────
function buildFileTree(dir, depth) {
  if (depth === 0) return null;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  return entries
    .filter(e => !e.name.startsWith('.') && e.name !== 'node_modules' && e.name !== 'DerivedData')
    .map(e => {
      const full = path.join(dir, e.name);
      return e.isDirectory()
        ? { name: e.name, type: 'dir', path: full, children: buildFileTree(full, depth - 1) }
        : { name: e.name, type: 'file', path: full };
    });
}

// ── mDNS Advertisement ────────────────────────────────────────────────────────
function advertiseMDNS() {
  try {
    const mdns = require('mdns-js');
    const svc = mdns.createAdvertisement(mdns.tcp('broski'), CONFIG.port, {
      name: `Broski Bridge @ ${os.hostname()}`,
    });
    svc.start();
    console.log('[bridge] mDNS → _broski._tcp.local');
  } catch (e) { console.log('[bridge] mDNS unavailable:', e.message); }
}

// ── Startup ───────────────────────────────────────────────────────────────────
function getLocalIP() {
  for (const iface of Object.values(os.networkInterfaces())) {
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
console.log('║     🤙 Broski Bridge Server v1.1       ║');
console.log('╚════════════════════════════════════════╝\n');
console.log(`  Listening : ${wsURL}`);
console.log(`  Backend   : ${CONFIG.backend}`);
console.log(`  Secret    : ${CONFIG.secret}\n`);
console.log('  Scan QR with Broski iOS app:\n');
qrcode.generate(pairingPayload, { small: true });
console.log(`\n  Manual: broski://pair?url=${encodeURIComponent(wsURL)}&secret=${CONFIG.secret}\n`);
advertiseMDNS();
console.log('[bridge] ready\n');
