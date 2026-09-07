/**
 * Headless end-to-end test of the Mac agent.
 *
 * Spawns the real prc-agent binary, then acts as a controller from Node: pairs with proof and
 * approval, authenticates, negotiates WebRTC with werift (an independent implementation, not
 * libwebrtc), opens the data channels, exchanges control messages, counts video RTP from the
 * agent's synthetic screen, and ends the session cleanly. No permissions, no browser, no display.
 *
 *   npm run e2e                 synthetic screen, input disabled (safe anywhere)
 *   npm run e2e -- --real-screen  capture the real screen (needs Screen Recording for this terminal)
 *   npm run e2e -- --no-media     signaling and authentication only
 *   npm run e2e -- --input        also inject one harmless mouse move on the host
 */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { RTCPeerConnection, RTCRtpCodecParameters, RTCIceCandidate as WeriftCandidate, type RTCDataChannel } from 'werift';
import {
  EnvelopeReceiver,
  EnvelopeSender,
  b64urlDecode,
  deviceIdFromPublicKey,
  fingerprint,
  generateIdentity,
  importPublicKey,
  pairingProof,
  serializeEnvelope,
  type Envelope,
  type Identity,
} from '@prc/protocol';

const args = process.argv.slice(2);
const MEDIA = !args.includes('--no-media');
const REAL_SCREEN = args.includes('--real-screen');
const INPUT = args.includes('--input');
const AGENT = process.env.PRC_AGENT ?? fileURLToPath(new URL('../../apps/mac-agent/.build/debug/prc-agent', import.meta.url));

// ---------------------------------------------------------------- reporting

const results: { name: string; ok: boolean; detail?: string; ms: number }[] = [];
async function step<T>(name: string, fn: () => Promise<T>): Promise<T> {
  const t0 = Date.now();
  try {
    const value = await fn();
    results.push({ name, ok: true, ms: Date.now() - t0, detail: typeof value === 'string' ? value : undefined });
    console.log(`  ok   ${name}${typeof value === 'string' ? `  (${value})` : ''}`);
    return value;
  } catch (e) {
    results.push({ name, ok: false, ms: Date.now() - t0, detail: String(e) });
    console.log(`  FAIL ${name}: ${e instanceof Error ? e.message : String(e)}`);
    throw e;
  }
}

function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout after ${ms} ms: ${label}`)), ms);
    p.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

// ---------------------------------------------------------------- agent process

class AgentProcess {
  proc: ChildProcessWithoutNullStreams;
  lines: string[] = [];
  private waiters: { re: RegExp; resolve: (m: RegExpMatchArray) => void }[] = [];

  constructor(dataDir: string) {
    const flags = ['--file-identity', '--data-dir', dataDir, '--port', '0', '--no-bonjour', '--name', 'E2E Host'];
    if (!MEDIA) flags.push('--no-media');
    else if (!REAL_SCREEN) flags.push('--synthetic-screen');
    if (!INPUT) flags.push('--no-input');
    this.proc = spawn(AGENT, flags, { stdio: ['pipe', 'pipe', 'pipe'] });
    createInterface({ input: this.proc.stdout }).on('line', (line) => this.onLine(line));
    createInterface({ input: this.proc.stderr }).on('line', (line) => { if (process.env.PRC_E2E_VERBOSE) console.log(`  [agent stderr] ${line}`); });
    this.proc.on('exit', (code) => this.onLine(`<<agent exited ${code}>>`));
  }

  private onLine(line: string) {
    if (process.env.PRC_E2E_VERBOSE) console.log(`  [agent] ${line}`);
    this.lines.push(line);
    for (const w of [...this.waiters]) {
      const m = line.match(w.re);
      if (m) { this.waiters.splice(this.waiters.indexOf(w), 1); w.resolve(m); }
    }
  }

  /** Resolves with the first line, past or future, that matches. */
  waitFor(re: RegExp, ms = 10000): Promise<RegExpMatchArray> {
    for (const line of this.lines) { const m = line.match(re); if (m) return Promise.resolve(m); }
    return withTimeout(new Promise((resolve) => this.waiters.push({ re, resolve })), ms, `agent line ${re}`);
  }

  type(command: string) { this.proc.stdin.write(command + '\n'); }

  async stop() {
    if (this.proc.exitCode !== null) return;
    this.type('quit');
    await withTimeout(new Promise<void>((r) => this.proc.once('exit', () => r())), 5000, 'agent exit').catch(() => this.proc.kill('SIGKILL'));
  }
}

// ---------------------------------------------------------------- signaling client

class Signaling {
  ws!: WebSocket;
  sender: EnvelopeSender;
  receiver!: EnvelopeReceiver;
  hostId: string;
  private handlers = new Map<string, (env: Envelope, payload: any) => void>();
  private waiters: { types: string[]; resolve: (r: { env: Envelope; payload: any }) => void }[] = [];
  dropped: string[] = [];
  identity: Identity;

  constructor(identity: Identity, hostId: string) {
    this.identity = identity;
    this.sender = new EnvelopeSender(identity);
    this.hostId = hostId;
  }

  async connect(port: number, resolveKey: (id: string, env: Envelope) => Promise<CryptoKey | null>) {
    this.receiver = new EnvelopeReceiver({ selfDeviceId: this.identity.deviceId, resolveKey: (id) => resolveKey(id, this.currentEnvelope!) });
    this.ws = new WebSocket(`ws://127.0.0.1:${port}/`);
    await withTimeout(new Promise<void>((resolve, reject) => { this.ws.onopen = () => resolve(); this.ws.onerror = () => reject(new Error('websocket error')); }), 5000, 'websocket open');
    this.ws.onmessage = (evt) => void this.onMessage(String(evt.data));
  }

  private currentEnvelope: Envelope | null = null;
  private async onMessage(text: string) {
    try { this.currentEnvelope = JSON.parse(text); } catch { this.dropped.push('unparseable'); return; }
    const res = await this.receiver.receive(text);
    if (!res.ok) { this.dropped.push(`${res.reason}${res.detail ? ` ${res.detail}` : ''}`); return; }
    const type = res.envelope.type;
    const w = this.waiters.find((x) => x.types.includes(type));
    if (w) { this.waiters.splice(this.waiters.indexOf(w), 1); w.resolve({ env: res.envelope, payload: res.payload }); return; }
    this.handlers.get(type)?.(res.envelope, res.payload);
  }

  on(type: string, handler: (env: Envelope, payload: any) => void) { this.handlers.set(type, handler); }

  waitFor(types: string[], ms = 10000): Promise<{ env: Envelope; payload: any }> {
    return withTimeout(new Promise((resolve) => this.waiters.push({ types, resolve })), ms, `envelope ${types.join('/')}`);
  }

  async send(type: any, session: string, payload: unknown) {
    this.ws.send(serializeEnvelope(await this.sender.build(type, this.hostId, session, payload)));
  }

  close() { try { this.ws.close(); } catch {} }
}

// ---------------------------------------------------------------- main

const dataDir = mkdtempSync(join(tmpdir(), 'prc-e2e-'));
const agent = new AgentProcess(dataDir);
let signaling: Signaling | null = null;
let pc: RTCPeerConnection | null = null;

async function main() {
  console.log(`PRC headless end-to-end  (media: ${MEDIA ? (REAL_SCREEN ? 'real screen' : 'synthetic screen') : 'off'}, input: ${INPUT ? 'on' : 'off'})`);

  const hostId = await step('agent starts and listens', async () => {
    const id = (await agent.waitFor(/^\s+device id\s+([0-9a-f]{64})/))[1];
    await agent.waitFor(/^listening on port (\d+)/);
    return id;
  });
  const port = Number((await agent.waitFor(/^listening on port (\d+)/))[1]);

  const identity = await generateIdentity();
  let hostKey: CryptoKey | null = null;
  signaling = new Signaling(identity, hostId);
  await step('websocket connects to the embedded signaling endpoint', async () => {
    await signaling!.connect(port, async (id, env) => {
      if (id !== hostId) return null;
      if (hostKey) return hostKey;
      // Before pairing completes, only a PAIR_RESULT carrying the key whose hash we already know is acceptable.
      if (env.type !== 'PAIR_RESULT') return null;
      const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(env.payload)));
      const raw = b64urlDecode(payload.host_public_key);
      if ((await deviceIdFromPublicKey(raw)) !== hostId) return null;
      return importPublicKey(raw);
    });
  });

  const qr = await step('pairing window opens with a valid QR payload', async () => {
    agent.type('pair');
    const line = (await agent.waitFor(/^\{.*"kind":"prc-pair".*\}$/))[0];
    const qr = JSON.parse(line);
    if (qr.host_device_id !== hostId || qr.host_key_hash !== hostId) throw new Error('QR host id mismatch');
    if (qr.expires_at < Date.now()) throw new Error('QR already expired');
    return qr;
  });

  await step('PAIR_REQUEST with proof reaches the host and shows the right fingerprint', async () => {
    const proof = await pairingProof(b64urlDecode(qr.pairing_code), qr.pairing_session_id, identity.deviceId);
    await signaling!.send('PAIR_REQUEST', '', { public_key: identity.publicKeyB64, device_name: 'E2E Controller', device_type: 'web', pairing_session_id: qr.pairing_session_id, proof });
    const m = await agent.waitFor(/controller fingerprint: ([0-9A-F-]{14})/);
    if (m[1] !== fingerprint(identity.deviceId)) throw new Error(`host showed ${m[1]}, expected ${fingerprint(identity.deviceId)}`);
  });

  await step('approval on the host yields a signed PAIR_RESULT', async () => {
    agent.type('y');
    const { payload } = await signaling!.waitFor(['PAIR_RESULT']);
    if (!payload.approved) throw new Error(`refused: ${payload.reason}`);
    hostKey = await importPublicKey(b64urlDecode(payload.host_public_key));
    await agent.waitFor(/^paired "E2E Controller"/);
  });

  await step('unknown device gets SESSION_REJECT untrusted', async () => {
    const stranger = await generateIdentity();
    const s2 = new Signaling(stranger, hostId);
    await s2.connect(port, async (id) => (id === hostId ? hostKey : null));
    await s2.send('SESSION_REQUEST', '', { client_nonce: randomNonce(), versions: [1], path: 'lan', capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 } });
    const { payload } = await s2.waitFor(['SESSION_REJECT']);
    s2.close();
    if (payload.reason !== 'untrusted') throw new Error(`reason ${payload.reason}`);
  });

  const clientNonce = randomNonce();
  const challenge = await step('SESSION_REQUEST is answered with a signed SESSION_CHALLENGE', async () => {
    await signaling!.send('SESSION_REQUEST', '', { client_nonce: clientNonce, versions: [1], path: 'lan', capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 } });
    const { env, payload } = await signaling!.waitFor(['SESSION_CHALLENGE', 'SESSION_REJECT']);
    if (env.type === 'SESSION_REJECT') throw new Error(`rejected: ${payload.reason}`);
    if (payload.client_nonce !== clientNonce) throw new Error('client nonce not echoed');
    if (env.session !== payload.session_id) throw new Error('envelope session differs from session_id');
    return payload;
  });
  const sessionId: string = challenge.session_id;

  const accept = await step('SESSION_AUTH is accepted with display info', async () => {
    await signaling!.send('SESSION_AUTH', sessionId, { client_nonce: clientNonce, host_nonce: challenge.host_nonce });
    const { env, payload } = await signaling!.waitFor(['SESSION_ACCEPT', 'SESSION_REJECT']);
    if (env.type === 'SESSION_REJECT') throw new Error(`rejected: ${payload.reason}`);
    if (payload.host_nonce !== challenge.host_nonce || payload.client_nonce !== clientNonce) throw new Error('nonce mismatch in accept');
    await agent.waitFor(/authenticated, waiting for WebRTC offer/);
    return `${payload.display.width_px}x${payload.display.height_px} @${payload.display.scale}x`;
  });
  void accept;

  if (!MEDIA) {
    await step('signaling-only mode: offer is answered with SESSION_END error', async () => {
      await signaling!.send('SDP_OFFER', sessionId, { sdp: 'v=0\r\n', ice_restart: false });
      const { payload } = await signaling!.waitFor(['SESSION_END']);
      if (payload.reason !== 'error') throw new Error(`reason ${payload.reason}`);
    });
  } else {
    await runMedia(sessionId);
  }

  await step('agent shuts down cleanly', async () => {
    await agent.stop();
    await agent.waitFor(/<<agent exited 0>>/, 5000);
  });
}

async function runMedia(sessionId: string) {
  const peer = new RTCPeerConnection({
    iceUseIpv6: false,
    codecs: {
      video: [new RTCRtpCodecParameters({
        mimeType: 'video/H264', clockRate: 90000,
        rtcpFeedback: [{ type: 'nack' }, { type: 'nack', parameter: 'pli' }, { type: 'ccm', parameter: 'fir' }, { type: 'goog-remb' }],
        parameters: 'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f',
      })],
    },
  });
  pc = peer;
  const stats = { packets: 0, bytes: 0, keyframes: 0 };
  const control = new Map<string, (msg: any) => void>();
  const channels: Record<string, RTCDataChannel> = {};
  for (const [label, opts] of Object.entries({ 'input-lossy': { ordered: false, maxRetransmits: 0 }, 'input-reliable': { ordered: true }, control: { ordered: true } })) {
    const dc = peer.createDataChannel(label, opts);
    dc.onMessage.subscribe((data) => {
      const msg = JSON.parse(typeof data === 'string' ? data : Buffer.from(data as Uint8Array).toString('utf8'));
      control.get(msg.type)?.(msg);
    });
    channels[label] = dc;
  }
  peer.addTransceiver('video', { direction: 'recvonly' });
  peer.onTrack.subscribe((track) => {
    track.onReceiveRtp.subscribe((rtp) => {
      stats.packets += 1;
      stats.bytes += rtp.payload.length;
      // H.264 NAL type 5 (IDR) directly or inside an FU-A (type 28) start fragment, or an STAP-A (24) carrying one.
      const p = rtp.payload;
      const nal = p[0]! & 0x1f;
      if (nal === 5 || (nal === 28 && (p[1]! & 0x80) !== 0 && (p[1]! & 0x1f) === 5) || nal === 24) stats.keyframes += 1;
    });
  });
  signaling!.on('ICE_CANDIDATE', (_env, payload) => {
    void peer.addIceCandidate(new WeriftCandidate({ candidate: payload.candidate, sdpMid: payload.sdp_mid ?? undefined, sdpMLineIndex: payload.sdp_mline_index ?? undefined })).catch(() => {});
  });
  peer.onIceCandidate.subscribe((c) => {
    if (!c) return;
    void signaling!.send('ICE_CANDIDATE', sessionId, { candidate: c.candidate, sdp_mid: c.sdpMid ?? null, sdp_mline_index: c.sdpMLineIndex ?? null });
  });

  await step('SDP_OFFER from an independent WebRTC stack gets an H.264 SDP_ANSWER', async () => {
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await signaling!.send('SDP_OFFER', sessionId, { sdp: offer.sdp, ice_restart: false });
    const { payload } = await signaling!.waitFor(['SDP_ANSWER', 'SESSION_END'], 15000);
    if (!payload.sdp) throw new Error(`session ended: ${payload.reason}`);
    if (!/H264/.test(payload.sdp)) throw new Error('answer has no H264');
    if (!/m=application/.test(payload.sdp)) throw new Error('answer has no data channel m-line');
    await peer.setRemoteDescription({ type: 'answer', sdp: payload.sdp });
  });

  await step('ICE connects and the agent reports the path', async () => {
    if (peer.connectionState !== 'connected') {
      await withTimeout(new Promise<void>((resolve, reject) => {
        peer.connectionStateChange.subscribe((s) => { if (s === 'connected') resolve(); if (s === 'failed') reject(new Error('ICE failed')); });
      }), 20000, 'peer connection connected');
    }
    const m = await agent.waitFor(/"E2E Controller" connected: (.+)$/, 10000);
    return m[1];
  });

  await step('all three data channels open and the host announces display_info', async () => {
    const displayInfo = new Promise<any>((resolve) => control.set('display_info', resolve));
    await withTimeout(Promise.all(Object.values(channels).map((dc) => dc.readyState === 'open' ? Promise.resolve() : new Promise<void>((resolve) => dc.stateChanged.subscribe((s) => { if (s === 'open') resolve(); })))), 10000, 'channels open');
    channels.control!.send(JSON.stringify({ v: 1, type: 'hello', ts: 0, versions: [1], app: 'web-harness', app_version: 'e2e' }));
    const info = await withTimeout(displayInfo, 10000, 'display_info');
    return `${info.width_px}x${info.height_px}`;
  });

  await step('ping over the control channel gets a pong with the same nonce', async () => {
    const nonce = Math.floor(Math.random() * 0xffffffff);
    const pong = new Promise<any>((resolve) => control.set('pong', resolve));
    const t0 = performance.now();
    channels.control!.send(JSON.stringify({ v: 1, type: 'ping', ts: 1, nonce }));
    const msg = await withTimeout(pong, 5000, 'pong');
    if (msg.nonce !== nonce) throw new Error(`nonce ${msg.nonce} != ${nonce}`);
    return `${(performance.now() - t0).toFixed(1)} ms`;
  });

  await step('a message on the wrong channel and a forbidden type are ignored without dropping the session', async () => {
    channels['input-lossy']!.send(JSON.stringify({ v: 1, type: 'key_down', ts: 1, code: 'KeyA', modifiers: [], repeat: false }));
    channels['input-reliable']!.send(JSON.stringify({ v: 1, type: 'execute_shell', ts: 1, cmd: 'id' }));
    const nonce = 7;
    const pong = new Promise<any>((resolve) => control.set('pong', resolve));
    channels.control!.send(JSON.stringify({ v: 1, type: 'ping', ts: 2, nonce }));
    await withTimeout(pong, 5000, 'pong after bad messages');
  });

  if (INPUT) {
    await step('one mouse move is accepted', async () => {
      channels['input-lossy']!.send(JSON.stringify({ v: 1, type: 'mouse_move', ts: 3, display_id: '0', x: 0.5, y: 0.5 }));
      await new Promise((r) => setTimeout(r, 200));
    });
  }

  await step('video RTP arrives from the agent', async () => {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline && stats.packets < 60) await new Promise((r) => setTimeout(r, 100));
    if (stats.packets < 60) throw new Error(`only ${stats.packets} packets in 10 s`);
    const t0 = stats.packets;
    await new Promise((r) => setTimeout(r, 2000));
    return `${stats.packets} packets, ${(stats.bytes / 1024).toFixed(0)} KiB, ${stats.keyframes} keyframe fragments, ~${((stats.packets - t0) / 2).toFixed(0)} packets/s`;
  });

  await step('bye and SESSION_END close the session on the host', async () => {
    channels.control!.send(JSON.stringify({ v: 1, type: 'bye', ts: 9, reason: 'user' }));
    await signaling!.send('SESSION_END', sessionId, { reason: 'user' });
    await agent.waitFor(/^session ended: user/, 10000);
    await peer.close();
    pc = null;
  });
}

function randomNonce() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return Buffer.from(b).toString('base64url');
}

let exitCode = 0;
try {
  await main();
} catch (e) {
  exitCode = 1;
  if (!results.length || results[results.length - 1]!.ok) console.log(`  FAIL outside a step: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
} finally {
  if (pc) await pc.close().catch(() => {});
  signaling?.close();
  await agent.stop();
  rmSync(dataDir, { recursive: true, force: true });
  const passed = results.filter((r) => r.ok).length;
  console.log(`\n${passed}/${results.length} steps passed${signaling?.dropped.length ? `; dropped inbound: ${signaling.dropped.join(', ')}` : ''}`);
  if (exitCode) {
    console.log('last agent output:');
    for (const l of agent.lines.slice(-15)) console.log(`  | ${l}`);
  }
  process.exit(exitCode);
}
