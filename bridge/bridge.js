#!/usr/bin/env node
/**
 * Broski Bridge Server v1.2.0
 * Changes:
 *  - dotenv loaded at startup
 *  - ~ and ~/ path expansion for file_tree / file_read
 *  - mDNS advertises port in TXT record; iOS reads it
 *  - approval contract: tool_use events carry a toolId;
 *    { type:'tool_approve', toolId } unblocks a waiting ClaudeCodeAdapter
 *  - relay TLS note: bridge itself stays plain ws:// for LAN;
 *    wss:// termination is handled by fly/ngrok/cloudflare upstream
 */

require('dotenv').config();

const { WebSocketServer, WebSocket } = require('ws');
const { spawn } = require('child_process');
const os = require('os');
const crypto = require('crypto');
const qrcode = require('qrcode-terminal');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');

const CONFIG = {
  port: parseInt(process.env.PORT || '7337', 10),
  secret: process.env.BROSKI_SECRET || crypto.randomBytes(16).toString('hex'),
  backend: process.env.BACKEND || 'claude',
  customCommand: process.env.CUSTOM_CMD || null,
  rttSampleWindow: 5,
  batchIntervalMin: 8,
  batchIntervalMax: 100,
};

// ── Helpers ───────────────────────────────────────────────────────────────────
function expandPath(p) {
  if (!p) return process.cwd();
  if (p === '~' || p.startsWith('~/')) return p.replace('~', os.homedir());
  return p;
}

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
    this.history = [];
  }
  send(text) { throw new Error('Not implemented'); }
  approve(toolId) {}
  stop() {}
  _emit(type, data) { this.onEvent({ type, sessionId: this.sessionId, ts: Date.now(), id: uuidv4(), ...data }); }
}

/**
 * ClaudeCodeAdapter — one-shot CLI per message.
 *
 * Approval contract:
 *  - When a tool_use block arrives, the adapter emits it with a toolId.
 *  - The iOS app shows a DiffApproveView sheet.
 *  - If the user taps Approve, iOS sends { type:'tool_approve', toolId }.
 *  - If the user taps Deny, iOS sends { type:'tool_deny', toolId }.
 *  - For Claude Code (non-interactive), the adapter stores the decision
 *    and prepends it to the NEXT user message as context so Claude knows
 *    whether its last tool was accepted or rejected.
 *  - A custom/opencode adapter can use a real pause/resume pipe instead.
 */
class ClaudeCodeAdapter extends BackendAdapter {
  constructor(sessionId, onEvent, workdir) {
    super(sessionId, onEvent);
    this.workdir = workdir;
    this.running = false;
    this.pendingApprovals = new Map(); // toolId → 'approved'|'denied'
  }

  approve(toolId) { this.pendingApprovals.set(toolId, 'approved'); }
  deny(toolId)    { this.pendingApprovals.set(toolId, 'denied'); }

  send(userText) {
    if (this.running) {
      this._emit('error', { text: 'Agent is busy — please wait.' });
      return;
    }

    // Prepend any pending tool approval/denial decisions as context
    let effectiveText = userText;
    if (this.pendingApprovals.size > 0) {
      const decisions = [...this.pendingApprovals.entries()]
        .map(([id, v]) => `Tool ${id}: ${v}`).join(', ');
      this.pendingApprovals.clear();
      effectiveText = `[Tool decisions: ${decisions}]\n${userText}`;
    }

    this.history.push({ role: 'user', content: effectiveText });
    this._emit('status', { status: 'thinking', backend: 'claude' });
    this.running = true;

    const historyContext = this.history.slice(0, -1)
      .map(h => `${h.role === 'user' ? 'Human' : 'Assistant'}: ${h.content}`)
      .join('\n');
    const fullPrompt = historyContext
      ? `Previous conversation:\n${historyContext}\n\nHuman: ${effectiveText}`
      : effectiveText;

    const args = ['-p', fullPrompt, '--output-format', 'stream-json', '--verbose', '--no-interactive'];
    const proc = spawn('claude', args, {
      cwd: this.workdir,
      env: { ...process.env, FORCE_COLOR: '0' },
    });

    let assistantText = '';
    proc.stdout.on('data', (chunk) => {
      chunk.toString().split('\n').filter(Boolean).forEach(line => {
        try { this._handleClaudeMessage(JSON.parse(line), (t) => { assistantText += t; }); }
        catch { this._emit('output', { text: line }); }
      });
    });
    proc.stderr.on('data', (d) => { const t = d.toString().trim(); if (t) this._emit('error', { text: t }); });
    proc.on('exit', (code) => {
      this.running = false;
      if (assistantText) this.history.push({ role: 'assistant', content: assistantText });
      this._emit('status', { status: 'idle', backend: 'claude', exitCode: code });
    });
  }

  _handleClaudeMessage(msg, onText) {
    switch (msg.type) {
      case 'assistant':
        if (msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') {
              // Stream token by token by emitting each word with a 'delta' flag
              const words = block.text.split(/(\s+)/);
              let streamed = '';
              for (const word of words) {
                streamed += word;
                this._emit('text_delta', { delta: word, sessionId: this.sessionId });
              }
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
      default: break;
    }
  }

  stop() { this.running = false; }
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
    this.proc.stdout.on('data', (c) => c.toString().split('\n').filter(Boolean).forEach(l => {
      try { this._emit('raw', { data: JSON.parse(l) }); } catch { this._emit('output', { text: l }); }
    }));
    this.proc.stderr.on('data', (d) => this._emit('error', { text: d.toString() }));
    this.proc.on('exit', (c) => this._emit('status', { status: 'exited', code: c }));
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
    this.proc.on('exit', (c) => this._emit('status', { status: 'exited', code: c }));
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
  if (a.start) a.start();
  return a;
}

// ── Session Manager ───────────────────────────────────────────────────────────
class SessionManager {
  constructor() { this.sessions = new Map(); }
  create(workdir, backend, onEvent) {
    const sessionId = uuidv4();
    const resolvedWorkdir = expandPath(workdir);
    const adapter = createAdapter(backend, sessionId, onEvent, resolvedWorkdir);
    this.sessions.set(sessionId, { adapter, workdir: resolvedWorkdir, backend, clients: new Set() });
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
  approve(id, toolId) { this.sessions.get(id)?.adapter.approve(toolId); }
  deny(id, toolId) { this.sessions.get(id)?.adapter.deny(toolId); }
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
      ws.send(JSON.stringify({ type: 'auth_ok', bridgeVersion: '1.2.0' }));
      return;
    }
    if (!ws.authenticated) { ws.send(JSON.stringify({ type: 'error', message: 'Not authenticated' })); return; }
    if (msg.type === 'pong') { batcher.recordPong(); return; }

    switch (msg.type) {
      case 'session_create': {
        const workdir = expandPath(msg.workdir);
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
        if (!s) {
          // Session not found — tell client to create a new one
          ws.send(JSON.stringify({ type: 'session_not_found', requestedId: msg.sessionId }));
          return;
        }
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
      case 'tool_approve':
        if (ws.sessionId && msg.toolId) sessions.approve(ws.sessionId, msg.toolId); break;
      case 'tool_deny':
        if (ws.sessionId && msg.toolId) sessions.deny(ws.sessionId, msg.toolId); break;
      case 'ping':
        batcher.recordPing();
        ws.send(JSON.stringify({ type: 'ping_ack', ts: Date.now() })); break;
      case 'file_tree': {
        const dir = expandPath(msg.path);
        try { ws.send(JSON.stringify({ type: 'file_tree', path: dir, tree: buildFileTree(dir, 4) })); }
        catch (e) { ws.send(JSON.stringify({ type: 'error', message: e.message })); }
        break;
      }
      case 'file_read': {
        const fp = expandPath(msg.path);
        try { ws.send(JSON.stringify({ type: 'file_content', path: fp, content: fs.readFileSync(fp, 'utf8') })); }
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

// ── mDNS Advertisement — port in TXT record so iOS can read it ────────────────
function advertiseMDNS() {
  try {
    const mdns = require('mdns-js');
    const svc = mdns.createAdvertisement(mdns.tcp('broski'), CONFIG.port, {
      name: `Broski Bridge @ ${os.hostname()}`,
      txt: { port: String(CONFIG.port) },
    });
    svc.start();
    console.log(`[bridge] mDNS → _broski._tcp.local (port ${CONFIG.port})`);
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
console.log('║     🤙 Broski Bridge Server v1.2       ║');
console.log('╚════════════════════════════════════════╝\n');
console.log(`  Listening : ${wsURL}`);
console.log(`  Backend   : ${CONFIG.backend}`);
console.log(`  Secret    : ${CONFIG.secret}`);
console.log(`  TLS note  : bridge is plain ws:// on LAN;`);
console.log(`              wss:// is terminated by Fly/ngrok/Cloudflare upstream\n`);
console.log('  Scan QR with Broski iOS app:\n');
qrcode.generate(pairingPayload, { small: true });
console.log(`\n  Manual: broski://pair?url=${encodeURIComponent(wsURL)}&secret=${CONFIG.secret}\n`);
advertiseMDNS();
console.log('[bridge] ready\n');
