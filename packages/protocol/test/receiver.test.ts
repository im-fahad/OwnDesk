import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EnvelopeReceiver,
  EnvelopeSender,
  MAX_ENVELOPE_BYTES,
  generateIdentity,
  importPublicKeyB64,
  serializeEnvelope,
  type Envelope,
} from '../src/index.ts';
import { loadVector } from './helpers.ts';

type EnvelopeVector = {
  receiver: { self_device_id: string; trusted: Record<string, string>; now_ms: number; accept_pair_requests: boolean };
  cases: { name: string; envelope: Envelope; expect: string }[];
};
const vec = loadVector<EnvelopeVector>('envelopes.json');

async function receiverFromVector(): Promise<EnvelopeReceiver> {
  const keys = new Map<string, CryptoKey>();
  for (const [id, pub] of Object.entries(vec.receiver.trusted)) keys.set(id, await importPublicKeyB64(pub));
  return new EnvelopeReceiver({
    selfDeviceId: vec.receiver.self_device_id,
    resolveKey: (id) => keys.get(id) ?? null,
    now: () => vec.receiver.now_ms,
    acceptPairRequests: vec.receiver.accept_pair_requests,
  });
}

test('receiver vector cases in order', async () => {
  const r = await receiverFromVector();
  for (const c of vec.cases) {
    const res = await r.receive(serializeEnvelope(c.envelope));
    const got = res.ok ? 'ok' : res.reason;
    assert.equal(got, c.expect, `${c.name}: ${res.ok ? '' : res.detail ?? ''}`);
  }
});

test('oversized envelope is rejected before parsing', async () => {
  const r = await receiverFromVector();
  const big = serializeEnvelope({ ...vec.cases[0]!.envelope, payload: 'A'.repeat(MAX_ENVELOPE_BYTES) });
  const res = await r.receive(big);
  assert.equal(res.ok, false);
  if (!res.ok) assert.equal(res.reason, 'too_large');
});

test('garbage is malformed, not a crash', async () => {
  const r = await receiverFromVector();
  for (const raw of ['', '{', 'null', '[]', '{"v":1}', new Uint8Array([0xff, 0xfe])]) {
    const res = await r.receive(raw);
    assert.equal(res.ok, false);
    if (!res.ok) assert.equal(res.reason, 'malformed');
  }
});

test('PAIR_REQUEST is refused when pairing is not open', async () => {
  const keys = new Map<string, CryptoKey>();
  for (const [id, pub] of Object.entries(vec.receiver.trusted)) keys.set(id, await importPublicKeyB64(pub));
  const r = new EnvelopeReceiver({ selfDeviceId: vec.receiver.self_device_id, resolveKey: (id) => keys.get(id) ?? null, now: () => vec.receiver.now_ms });
  const pair = vec.cases.find((c) => c.name.startsWith('PAIR_REQUEST self-certified'))!;
  const res = await r.receive(serializeEnvelope(pair.envelope));
  assert.equal(res.ok, false);
  if (!res.ok) assert.equal(res.reason, 'unknown_sender');
});

test('live sender and receiver agree, and forgetSession resets replay state', async () => {
  const host = await generateIdentity();
  const ctl = await generateIdentity();
  let now = 5_000_000;
  const sender = new EnvelopeSender(ctl, () => now);
  const receiver = new EnvelopeReceiver({ selfDeviceId: host.deviceId, resolveKey: (id) => (id === ctl.deviceId ? ctl.publicKey : null), now: () => now });
  const payload = { client_nonce: 'AAECAwQFBgcICQoLDA0ODw', versions: [1], path: 'lan', capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 } };

  const e1 = await sender.build('SESSION_REQUEST', host.deviceId, '', payload);
  const r1 = await receiver.receive(serializeEnvelope(e1));
  assert.equal(r1.ok, true);
  if (r1.ok) assert.deepEqual(r1.payload, payload);

  now += 299_000;
  const e2 = await sender.build('SESSION_REQUEST', host.deviceId, '', payload);
  assert.equal((await receiver.receive(serializeEnvelope(e2))).ok, true, 'within skew window');

  const replay = await receiver.receive(serializeEnvelope(e1));
  assert.equal(replay.ok, false);
  if (!replay.ok) assert.equal(replay.reason, 'replayed');

  receiver.forgetSession(ctl.deviceId, '');
  now = e1.ts + 300_001;
  assert.equal((await receiver.receive(serializeEnvelope(e1))).ok, false, 'stale once outside the skew window');
  now = e1.ts;
  assert.equal((await receiver.receive(serializeEnvelope(e1))).ok, true, 'accepted again once state is forgotten and clock matches');

  receiver.forgetSender(ctl.deviceId);
  assert.equal((await receiver.receive(serializeEnvelope(e1))).ok, true);
});
