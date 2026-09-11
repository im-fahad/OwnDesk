import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import {
  CHANNEL_FOR_TYPE,
  DATACHANNEL_TYPES,
  SCHEMA_DIR,
  SERVER_FRAME_KINDS,
  SIGNALING_TYPES,
  parseDataChannelMessage,
  validateDataChannelMessage,
  validateServerFrame,
  validateSignalingPayload,
} from '../src/index.ts';
import { SAMPLE } from './helpers.ts';

const names = (dir: string) => readdirSync(join(SCHEMA_DIR, dir)).map((f) => f.replace(/\.json$/, '')).sort();

test('type lists and schema directories agree', () => {
  assert.deepEqual(names('signaling'), [...SIGNALING_TYPES].sort());
  assert.deepEqual(names('datachannel'), [...DATACHANNEL_TYPES].sort());
  assert.deepEqual(names('server'), [...SERVER_FRAME_KINDS].sort());
  assert.deepEqual(Object.keys(CHANNEL_FOR_TYPE).sort(), [...DATACHANNEL_TYPES].sort());
});

const validSignaling: Record<(typeof SIGNALING_TYPES)[number], object> = {
  PAIR_REQUEST: { public_key: SAMPLE.publicKey, device_name: 'Phone', device_type: 'android', pairing_session_id: SAMPLE.bytes16, proof: SAMPLE.bytes32 },
  PAIR_RESULT: { approved: false, reason: 'denied', host_public_key: SAMPLE.publicKey, host_name: 'Mac Mini', rendezvous_url: null },
  SESSION_REQUEST: { client_nonce: SAMPLE.bytes16, versions: [1], path: 'cloud', capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 } },
  SESSION_CHALLENGE: { host_nonce: SAMPLE.bytes16, client_nonce: SAMPLE.bytes16, session_id: SAMPLE.bytes16, version: 1, expires_at: 1 },
  SESSION_AUTH: { client_nonce: SAMPLE.bytes16, host_nonce: SAMPLE.bytes16 },
  SESSION_ACCEPT: { client_nonce: SAMPLE.bytes16, host_nonce: SAMPLE.bytes16, display: SAMPLE.display, resume_window_s: 600 },
  SESSION_REJECT: { reason: 'busy' },
  SDP_OFFER: { sdp: 'v=0', ice_restart: true },
  SDP_ANSWER: { sdp: 'v=0' },
  ICE_CANDIDATE: { candidate: 'candidate:1 1 udp 1 1.2.3.4 5 typ host', sdp_mid: '0', sdp_mline_index: 0 },
  SESSION_RESUME: {},
  SESSION_END: { reason: 'user' },
};

test('every signaling payload has a passing sample and fails when a required field is missing', () => {
  for (const type of SIGNALING_TYPES) {
    const sample = validSignaling[type];
    assert.deepEqual(validateSignalingPayload(type, sample), { valid: true, errors: [] }, type);
    for (const key of Object.keys(sample)) {
      const { [key]: _omit, ...rest } = sample as Record<string, unknown>;
      assert.equal(validateSignalingPayload(type, rest).valid, false, `${type} without ${key}`);
    }
    assert.equal(validateSignalingPayload(type, null).valid, false);
    assert.equal(validateSignalingPayload(type, 'x').valid, false);
  }
  assert.equal(validateSignalingPayload('NOPE', {}).valid, false);
  assert.equal(validateSignalingPayload('SESSION_REJECT', { reason: 'whatever' }).valid, false);
  assert.equal(validateSignalingPayload('SESSION_REQUEST', { ...validSignaling.SESSION_REQUEST, capabilities: { codecs: ['VP8'], max_height: 1080, max_fps: 60 } }).valid, false);
  assert.equal(validateSignalingPayload('SDP_OFFER', { sdp: 'x'.repeat(40000), ice_restart: false }).valid, false);
});

test('data channel messages: valid samples parse and land on the right channel', () => {
  const ok = (m: object, channel: string) => {
    const r = parseDataChannelMessage(JSON.stringify(m));
    assert.equal(r.ok, true, JSON.stringify(m) + (r.ok ? '' : ` ${r.reason} ${r.detail ?? ''}`));
    if (r.ok) assert.equal(r.channel, channel);
  };
  ok({ v: 1, type: 'mouse_move', ts: 1, display_id: 'main', x: 0.5, y: 1 }, 'input-lossy');
  ok({ v: 1, type: 'mouse_move_rel', ts: 1, dx: -3.5, dy: 12 }, 'input-lossy');
  ok({ v: 1, type: 'mouse_down', ts: 1, button: 'right' }, 'input-reliable');
  ok({ v: 1, type: 'mouse_up', ts: 1, button: 'left' }, 'input-reliable');
  ok({ v: 1, type: 'scroll', ts: 1, dx: 0, dy: -120, precise: true, phase: 'changed' }, 'input-reliable');
  ok({ v: 1, type: 'scroll', ts: 1, dx: 0, dy: 3, precise: false }, 'input-reliable');
  ok({ v: 1, type: 'key_down', ts: 1, code: 'KeyA', modifiers: ['meta', 'shift'], repeat: false }, 'input-reliable');
  ok({ v: 1, type: 'key_up', ts: 1, code: 'MetaLeft', modifiers: [] }, 'input-reliable');
  ok({ v: 1, type: 'text', ts: 1, text: 'héllo 👋' }, 'input-reliable');
  ok({ v: 1, type: 'hello', ts: 0, versions: [1], app: 'mac-controller', app_version: '0.1.0' }, 'control');
  ok({ v: 1, type: 'display_info', ts: 0, ...SAMPLE.display }, 'control');
  ok({ v: 1, type: 'capture_state', ts: 0, state: 'paused_locked' }, 'control');
  ok({ v: 1, type: 'capture_state', ts: 0, state: 'active', detail: 'resumed' }, 'control');
  ok({ v: 1, type: 'stream_settings', ts: 0, max_fps: 30 }, 'control');
  ok({ v: 1, type: 'ping', ts: 0, nonce: 7 }, 'control');
  ok({ v: 1, type: 'pong', ts: 0, nonce: 7 }, 'control');
  ok({ v: 1, type: 'bye', ts: 0, reason: 'idle_timeout' }, 'control');
});

test('data channel messages: invalid inputs are rejected with the right reason', () => {
  const bad = (raw: string, reason: string) => {
    const r = parseDataChannelMessage(raw);
    assert.equal(r.ok, false, raw);
    if (!r.ok) assert.equal(r.reason, reason, raw);
  };
  bad('x'.repeat(5000), 'too_large');
  bad('{', 'malformed');
  bad('"str"', 'malformed');
  bad(JSON.stringify({ v: 1, type: 'execute_shell', ts: 1, cmd: 'rm -rf /' }), 'unknown_type');
  bad(JSON.stringify({ v: 1, type: 'mouse_move', ts: 1, display_id: 'main', x: 1.5, y: 0 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'mouse_move', ts: 1, display_id: 'main', x: -0.1, y: 0 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'mouse_move', ts: 1, x: 0.5, y: 0.5 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'mouse_move_rel', ts: 1, dx: 5000, dy: 0 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'mouse_down', ts: 1, button: 'back' }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'capture_state', ts: 1, state: 'asleep' }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'capture_state', ts: 1 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'scroll', ts: 1, dx: 0, dy: 20000, precise: true }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'key_down', ts: 1, code: 'Key A', modifiers: [], repeat: false }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'key_down', ts: 1, code: 'KeyA', modifiers: ['hyper'], repeat: false }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'key_down', ts: 1, code: 'KeyA', modifiers: ['shift', 'shift'], repeat: false }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'text', ts: 1, text: '' }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'text', ts: 1, text: 'a'.repeat(257) }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'ping', ts: 1 }), 'invalid');
  bad(JSON.stringify({ v: 1, type: 'bye', ts: 1, reason: 'because' }), 'invalid');
});

test('text length limit counts code points, not UTF-16 units', () => {
  const emoji256 = '👋'.repeat(256);
  assert.equal(validateDataChannelMessage({ v: 1, type: 'text', ts: 1, text: emoji256 }).valid, true);
  assert.equal(validateDataChannelMessage({ v: 1, type: 'text', ts: 1, text: emoji256 + 'a' }).valid, false);
});

test('messages on the wrong channel are rejected', () => {
  const r1 = parseDataChannelMessage(JSON.stringify({ v: 1, type: 'key_down', ts: 1, code: 'KeyA', modifiers: [], repeat: false }), 'input-lossy');
  assert.equal(r1.ok, false);
  if (!r1.ok) assert.equal(r1.reason, 'wrong_channel');
  const r2 = parseDataChannelMessage(JSON.stringify({ v: 1, type: 'mouse_move', ts: 1, display_id: 'main', x: 0, y: 0 }), 'input-lossy');
  assert.equal(r2.ok, true);
});

test('server frames validate', () => {
  assert.equal(validateServerFrame({ kind: 'auth_challenge', nonce: SAMPLE.bytes32, origin: 'prc.example.com' }).valid, true);
  assert.equal(validateServerFrame({ kind: 'auth', device_id: SAMPLE.deviceId, public_key: SAMPLE.publicKey, role: 'controller', sig: SAMPLE.signature }).valid, true);
  assert.equal(validateServerFrame({ kind: 'auth', device_id: SAMPLE.deviceId, public_key: SAMPLE.publicKey, role: 'admin', sig: SAMPLE.signature }).valid, false);
  assert.equal(validateServerFrame({ kind: 'auth_ok', ice_servers: [{ urls: ['turn:prc.example.com:3478?transport=udp'], username: '1:x', credential: 'c' }] }).valid, true);
  assert.equal(validateServerFrame({ kind: 'auth_ok', ice_servers: [{ urls: ['http://prc.example.com'] }] }).valid, false);
  assert.equal(validateServerFrame({ kind: 'trust_sync', controllers: [{ device_id: SAMPLE.deviceId, public_key: SAMPLE.publicKey, name: 'MacBook' }] }).valid, true);
  assert.equal(validateServerFrame({ kind: 'presence', device_id: SAMPLE.deviceId, online: true }).valid, true);
  const envelope = { v: 1, type: 'SDP_OFFER', from: SAMPLE.deviceId, to: SAMPLE.otherDeviceId, session: SAMPLE.bytes16, seq: 1, ts: 1, payload: 'e30', sig: SAMPLE.signature };
  assert.equal(validateServerFrame({ kind: 'relay', to: SAMPLE.otherDeviceId, envelope }).valid, true);
  assert.equal(validateServerFrame({ kind: 'relay', to: SAMPLE.otherDeviceId, envelope: { ...envelope, sig: 'x' } }).valid, false);
  assert.equal(validateServerFrame({ kind: 'error', code: 'peer_offline', message: 'host is offline' }).valid, true);
  assert.equal(validateServerFrame({ kind: 'ping' }).valid, true);
  assert.equal(validateServerFrame({ kind: 'shell', cmd: 'ls' }).valid, false);
});
