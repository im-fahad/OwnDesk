import * as P from './protocol.js';

const $ = (id) => document.getElementById(id);
const log = (msg, cls = '') => {
  const line = document.createElement('div');
  line.className = cls;
  line.textContent = `${new Date().toLocaleTimeString()}  ${msg}`;
  $('log').prepend(line);
};

const CHANNELS = {
  'input-lossy': { ordered: false, maxRetransmits: 0 },
  'input-reliable': { ordered: true },
  control: { ordered: true },
};
const CHANNEL_FOR = {
  mouse_move: 'input-lossy', mouse_move_rel: 'input-lossy',
  mouse_down: 'input-reliable', mouse_up: 'input-reliable', scroll: 'input-reliable', key_down: 'input-reliable', key_up: 'input-reliable', text: 'input-reliable',
  hello: 'control', stream_settings: 'control', ping: 'control', pong: 'control', bye: 'control',
};

const state = {
  identity: null,
  hosts: {},        // deviceId -> { publicKey, name, addresses }
  ws: null,
  sender: null,
  receiver: null,
  hostKey: null,
  host: null,       // { deviceId, publicKey, name }
  session: null,    // { id, clientNonce, hostNonce, display }
  pc: null,
  channels: {},
  pingTimer: null,
  missedPongs: 0,
  lastPing: 0,
  t0: performance.now(),
  pendingMove: null,
  moveTimer: null,
};

const ts = () => Math.round(performance.now() - state.t0);

function loadHosts() {
  try { state.hosts = JSON.parse(localStorage.getItem('prc.hosts') || '{}'); } catch { state.hosts = {}; }
}
function saveHosts() { localStorage.setItem('prc.hosts', JSON.stringify(state.hosts)); }

function renderHosts() {
  const select = $('host');
  select.innerHTML = '';
  for (const [id, h] of Object.entries(state.hosts)) {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = `${h.name}  ${P.fingerprint(id)}`;
    select.appendChild(opt);
  }
  const first = Object.values(state.hosts)[0];
  if (first && !$('address').value) $('address').value = first.addresses[0] || '';
  $('connect').disabled = !first;
}

function setStatus(text) { $('status').textContent = text; }

// ---------------------------------------------------------------- signaling transport

function openSocket(address) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${address}/`);
    ws.onopen = () => resolve(ws);
    ws.onerror = () => reject(new Error(`cannot reach ws://${address}`));
  });
}

function sendEnvelope(env) {
  state.ws.send(JSON.stringify(env));
  log(`→ ${env.type}${env.session ? '' : ' (no session)'}`, 'out');
}

// Waits for the next accepted envelope of one of the given types.
function waitFor(types, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { state.ws.removeEventListener('message', handler); reject(new Error(`timeout waiting for ${types.join('/')}`)); }, timeoutMs);
    const handler = async (evt) => {
      const result = await state.receiver.receive(evt.data);
      if (!result.ok) { log(`✗ dropped inbound: ${result.reason}`, 'err'); return; }
      log(`← ${result.envelope.type}`, 'in');
      if (types.includes(result.envelope.type)) {
        clearTimeout(timer);
        state.ws.removeEventListener('message', handler);
        resolve(result);
      } else {
        handleAsync(result);
      }
    };
    state.ws.addEventListener('message', handler);
  });
}

// ---------------------------------------------------------------- pairing

async function pair() {
  let qr;
  try { qr = JSON.parse($('qr').value.trim()); } catch { log('paste the QR payload JSON first', 'err'); return; }
  if (qr.kind !== 'prc-pair') { log('not a PRC pairing payload', 'err'); return; }
  if (Date.now() > qr.expires_at) { log('this pairing payload has expired', 'err'); return; }
  const address = $('pairAddress').value.trim() || qr.addresses[0];
  setStatus(`pairing with ${qr.host_name} at ${address}`);

  try {
    state.ws = await openSocket(address);
  } catch (e) { log(e.message, 'err'); setStatus('idle'); return; }

  // Until PAIR_RESULT arrives we know only the host's key hash. Verify the key carried in the result against it.
  state.sender = new P.Sender(state.identity);
  state.receiver = new P.Receiver(state.identity.deviceId, async (from, env) => {
    if (from !== qr.host_device_id || env.type !== 'PAIR_RESULT') return null;
    try {
      const payload = P.decodePayload(env.payload);
      const raw = P.unb64url(payload.host_public_key);
      if ((await P.deviceIdFromPublicKey(raw)) !== qr.host_key_hash) return null;
      return P.importPublicKey(raw);
    } catch { return null; }
  });

  const proof = await P.pairingProof(P.unb64url(qr.pairing_code), qr.pairing_session_id, state.identity.deviceId);
  const request = {
    public_key: state.identity.publicKeyB64,
    device_name: $('deviceName').value.trim() || 'Web Harness',
    device_type: 'web',
    pairing_session_id: qr.pairing_session_id,
    proof,
  };
  sendEnvelope(await state.sender.build('PAIR_REQUEST', qr.host_device_id, '', request));
  $('compare').textContent = `Approve on the Mac Mini only if it shows YOUR fingerprint ${state.identity.fingerprint}. The Mac Mini's fingerprint is ${P.fingerprint(qr.host_device_id)}.`;
  setStatus('waiting for approval on the host');

  try {
    const { payload } = await waitFor(['PAIR_RESULT'], 130000);
    if (payload.approved) {
      state.hosts[qr.host_device_id] = { publicKey: payload.host_public_key, name: payload.host_name, addresses: qr.addresses };
      saveHosts();
      renderHosts();
      $('address').value = address;
      log(`paired with ${payload.host_name}`, 'ok');
      setStatus('paired');
    } else {
      log(`pairing refused: ${payload.reason}`, 'err');
      setStatus('idle');
    }
  } catch (e) {
    log(e.message, 'err');
    setStatus('idle');
  }
  state.ws.close();
  state.ws = null;
  $('compare').textContent = '';
}

// ---------------------------------------------------------------- session

async function connect() {
  const hostId = $('host').value;
  const host = state.hosts[hostId];
  if (!host) return;
  const address = $('address').value.trim() || host.addresses[0];
  state.host = { deviceId: hostId, publicKey: host.publicKey, name: host.name };
  state.hostKey = await P.importPublicKey(P.unb64url(host.publicKey));
  setStatus(`connecting to ${host.name} at ${address}`);

  try {
    state.ws = await openSocket(address);
  } catch (e) { log(e.message, 'err'); setStatus('idle'); return; }
  state.ws.onclose = () => { log('signaling socket closed'); };

  state.sender = new P.Sender(state.identity);
  state.receiver = new P.Receiver(state.identity.deviceId, async (from) => (from === hostId ? state.hostKey : null));

  const clientNonce = P.randomB64url();
  sendEnvelope(await state.sender.build('SESSION_REQUEST', hostId, '', {
    client_nonce: clientNonce, versions: [1], path: 'lan', capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 },
  }));

  let result;
  try { result = await waitFor(['SESSION_CHALLENGE', 'SESSION_REJECT']); } catch (e) { log(e.message, 'err'); return teardown(); }
  if (result.envelope.type === 'SESSION_REJECT') { log(`rejected: ${result.payload.reason}`, 'err'); return teardown(); }
  const challenge = result.payload;
  if (challenge.client_nonce !== clientNonce) { log('challenge echoed the wrong client nonce', 'err'); return teardown(); }
  state.session = { id: challenge.session_id, clientNonce, hostNonce: challenge.host_nonce, display: null };

  sendEnvelope(await state.sender.build('SESSION_AUTH', hostId, challenge.session_id, { client_nonce: clientNonce, host_nonce: challenge.host_nonce }));
  try { result = await waitFor(['SESSION_ACCEPT', 'SESSION_REJECT']); } catch (e) { log(e.message, 'err'); return teardown(); }
  if (result.envelope.type === 'SESSION_REJECT') { log(`rejected: ${result.payload.reason}`, 'err'); return teardown(); }
  const accept = result.payload;
  if (accept.client_nonce !== clientNonce || accept.host_nonce !== challenge.host_nonce) { log('accept nonces mismatch', 'err'); return teardown(); }
  state.session.display = accept.display;
  log(`authenticated. display ${accept.display.display_id} ${accept.display.width_px}x${accept.display.height_px} @${accept.display.scale}x`, 'ok');
  setStatus('authenticated, negotiating WebRTC');

  await startWebRTC();
  state.ws.addEventListener('message', async (evt) => {
    const r = await state.receiver.receive(evt.data);
    if (!r.ok) { log(`✗ dropped inbound: ${r.reason}`, 'err'); return; }
    log(`← ${r.envelope.type}`, 'in');
    handleAsync(r);
  });
}

async function handleAsync({ envelope, payload }) {
  if (!state.session || envelope.session !== state.session.id) return;
  switch (envelope.type) {
    case 'SDP_ANSWER':
      await state.pc.setRemoteDescription({ type: 'answer', sdp: payload.sdp });
      break;
    case 'ICE_CANDIDATE':
      try { await state.pc.addIceCandidate({ candidate: payload.candidate, sdpMid: payload.sdp_mid, sdpMLineIndex: payload.sdp_mline_index }); } catch (e) { log(`addIceCandidate: ${e.message}`, 'err'); }
      break;
    case 'SESSION_END':
      log(`host ended the session: ${payload.reason}`);
      teardown(false);
      break;
  }
}

async function startWebRTC() {
  const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
  state.pc = pc;
  for (const [label, cfg] of Object.entries(CHANNELS)) {
    const ch = pc.createDataChannel(label, cfg);
    ch.onopen = () => {
      log(`data channel ${label} open`, 'ok');
      if (label === 'control') {
        sendData('hello', { versions: [1], app: 'web-harness', app_version: '0.1.0' });
        startPing();
      }
    };
    ch.onmessage = (e) => onData(label, e.data);
    state.channels[label] = ch;
  }
  const transceiver = pc.addTransceiver('video', { direction: 'recvonly' });
  try {
    const caps = RTCRtpReceiver.getCapabilities('video');
    if (caps && transceiver.setCodecPreferences) {
      const h264 = caps.codecs.filter((c) => /h264/i.test(c.mimeType));
      const rest = caps.codecs.filter((c) => !/h264/i.test(c.mimeType));
      transceiver.setCodecPreferences([...h264, ...rest]);
    }
  } catch (e) { log(`codec preference: ${e.message}`); }

  pc.ontrack = (e) => {
    $('video').srcObject = e.streams[0] || new MediaStream([e.track]);
    log('video track received', 'ok');
  };
  pc.onicecandidate = async (e) => {
    if (!e.candidate) return;
    sendEnvelope(await state.sender.build('ICE_CANDIDATE', state.host.deviceId, state.session.id, {
      candidate: e.candidate.candidate, sdp_mid: e.candidate.sdpMid, sdp_mline_index: e.candidate.sdpMLineIndex,
    }));
  };
  pc.onconnectionstatechange = async () => {
    log(`peer connection ${pc.connectionState}`);
    if (pc.connectionState === 'connected') {
      setStatus(`connected to ${state.host.name}: ${await selectedPath()}`);
      $('connect').disabled = true;
      $('disconnect').disabled = false;
    } else if (['failed', 'closed'].includes(pc.connectionState)) {
      setStatus(`peer connection ${pc.connectionState}`);
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  sendEnvelope(await state.sender.build('SDP_OFFER', state.host.deviceId, state.session.id, { sdp: offer.sdp, ice_restart: false }));
}

async function selectedPath() {
  const stats = await state.pc.getStats();
  let pairId = null;
  stats.forEach((s) => { if (s.type === 'transport' && s.selectedCandidatePairId) pairId = s.selectedCandidatePairId; });
  const pair = pairId && stats.get(pairId);
  if (!pair) return 'Direct';
  const local = stats.get(pair.localCandidateId), remote = stats.get(pair.remoteCandidateId);
  if (local?.candidateType === 'relay' || remote?.candidateType === 'relay') return 'Relayed';
  if (local?.candidateType === 'host' && remote?.candidateType === 'host') return 'Direct (LAN)';
  if (local?.candidateType === 'host' && isPrivate(local?.address ?? local?.ip)) return 'Direct (LAN)';
  if (remote?.candidateType === 'host' && isPrivate(remote?.address ?? remote?.ip)) return 'Direct (LAN)';
  if (isPrivate(local?.address ?? local?.ip) && isPrivate(remote?.address ?? remote?.ip)) return 'Direct (LAN)';
  return 'Direct (Internet)';
}

function isPrivate(address = '') {
  const a = address.toLowerCase();
  if (/^(10\.|192\.168\.|169\.254\.|127\.)/.test(a)) return true;
  const m = a.match(/^(172|100)\.(\d+)\./);
  if (m) { const n = Number(m[2]); return m[1] === '172' ? n >= 16 && n <= 31 : n >= 64 && n <= 127; }
  return /^(fc|fd|fe80)/.test(a) || a === '::1';
}

function sendData(type, fields) {
  const ch = state.channels[CHANNEL_FOR[type]];
  if (!ch || ch.readyState !== 'open') return false;
  ch.send(JSON.stringify({ v: 1, type, ts: ts(), ...fields }));
  return true;
}

function onData(label, text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  switch (msg.type) {
    case 'display_info':
      state.session.display = msg;
      log(`display_info ${msg.display_id} ${msg.width_px}x${msg.height_px}`);
      break;
    case 'pong':
      state.missedPongs = 0;
      $('rtt').textContent = `${Math.round(performance.now() - state.lastPing)} ms`;
      break;
    case 'bye':
      log(`host says bye: ${msg.reason}`);
      teardown(false);
      break;
  }
}

function startPing() {
  stopPing();
  state.pingTimer = setInterval(() => {
    if (state.missedPongs >= 3) { log('three pongs missed', 'err'); }
    state.missedPongs += 1;
    state.lastPing = performance.now();
    sendData('ping', { nonce: Math.floor(Math.random() * 0xffffffff) });
  }, 5000);
}
function stopPing() { if (state.pingTimer) clearInterval(state.pingTimer); state.pingTimer = null; }

async function disconnect() { await teardown(true); }

async function teardown(notify = true) {
  stopPing();
  if (notify && state.session && state.ws && state.ws.readyState === WebSocket.OPEN) {
    sendData('bye', { reason: 'user' });
    try { sendEnvelope(await state.sender.build('SESSION_END', state.host.deviceId, state.session.id, { reason: 'user' })); } catch {}
  }
  if (state.pc) { state.pc.close(); state.pc = null; }
  state.channels = {};
  if (state.ws) { state.ws.onclose = null; state.ws.close(); state.ws = null; }
  state.session = null;
  $('video').srcObject = null;
  $('connect').disabled = Object.keys(state.hosts).length === 0;
  $('disconnect').disabled = true;
  $('rtt').textContent = '';
  setStatus('idle');
}

// ---------------------------------------------------------------- input capture

function videoContentRect(video) {
  const box = video.getBoundingClientRect();
  const vw = video.videoWidth || 16, vh = video.videoHeight || 9;
  const scale = Math.min(box.width / vw, box.height / vh);
  const w = vw * scale, h = vh * scale;
  return { left: box.left + (box.width - w) / 2, top: box.top + (box.height - h) / 2, width: w, height: h };
}

function normalized(e) {
  const r = videoContentRect($('video'));
  const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

const BUTTONS = { 0: 'left', 1: 'middle', 2: 'right' };
function modifiers(e) {
  const m = [];
  if (e.shiftKey) m.push('shift');
  if (e.ctrlKey) m.push('control');
  if (e.altKey) m.push('alt');
  if (e.metaKey) m.push('meta');
  if (e.getModifierState && e.getModifierState('CapsLock')) m.push('capslock');
  return m;
}

function wireInput() {
  const video = $('video');
  const enabled = () => $('sendInput').checked && state.session?.display;
  video.addEventListener('mousemove', (e) => {
    if (!enabled()) return;
    const p = normalized(e);
    if (!p) return;
    state.pendingMove = p;
    if (!state.moveTimer) {
      state.moveTimer = setTimeout(() => {
        state.moveTimer = null;
        if (state.pendingMove) sendData('mouse_move', { display_id: state.session.display.display_id, ...state.pendingMove });
        state.pendingMove = null;
      }, 4);
    }
  });
  video.addEventListener('mousedown', (e) => { if (!enabled()) return; video.focus(); e.preventDefault(); sendData('mouse_down', { button: BUTTONS[e.button] || 'left' }); });
  video.addEventListener('mouseup', (e) => { if (!enabled()) return; e.preventDefault(); sendData('mouse_up', { button: BUTTONS[e.button] || 'left' }); });
  video.addEventListener('contextmenu', (e) => e.preventDefault());
  video.addEventListener('wheel', (e) => {
    if (!enabled()) return;
    e.preventDefault();
    const precise = e.deltaMode === 0;
    sendData('scroll', { dx: precise ? e.deltaX : e.deltaX, dy: precise ? e.deltaY : e.deltaY, precise });
  }, { passive: false });
  video.addEventListener('keydown', (e) => {
    if (!enabled() || !e.code) return;
    e.preventDefault();
    sendData('key_down', { code: e.code, modifiers: modifiers(e), repeat: e.repeat });
  });
  video.addEventListener('keyup', (e) => {
    if (!enabled() || !e.code) return;
    e.preventDefault();
    sendData('key_up', { code: e.code, modifiers: modifiers(e) });
  });
  $('sendText').addEventListener('click', () => {
    const text = $('text').value;
    if (!text) return;
    if (sendData('text', { text })) { $('text').value = ''; } else { log('not connected', 'err'); }
  });
}

// ---------------------------------------------------------------- boot

async function boot() {
  state.identity = await P.loadIdentity();
  $('deviceId').textContent = state.identity.deviceId;
  $('fingerprint').textContent = state.identity.fingerprint;
  loadHosts();
  renderHosts();
  wireInput();
  $('pair').addEventListener('click', pair);
  $('connect').addEventListener('click', connect);
  $('disconnect').addEventListener('click', disconnect);
  $('host').addEventListener('change', () => { $('address').value = state.hosts[$('host').value]?.addresses[0] || ''; });
  $('forget').addEventListener('click', () => { delete state.hosts[$('host').value]; saveHosts(); $('address').value = ''; renderHosts(); });
  $('resetIdentity').addEventListener('click', () => {
    if (!confirm('Reset this browser\'s identity? Every host will need to pair again.')) return;
    P.resetIdentity(); localStorage.removeItem('prc.hosts'); location.reload();
  });
  log(`identity ${state.identity.fingerprint} ready`);
}

boot().catch((e) => log(`boot failed: ${e.message}`, 'err'));
