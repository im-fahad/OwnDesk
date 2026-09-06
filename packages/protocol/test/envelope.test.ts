import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  EnvelopeSender,
  decodePayload,
  encodePayload,
  generateIdentity,
  signEnvelope,
  signingInput,
  utf8Decode,
  verifyEnvelopeSignature,
  type UnsignedEnvelope,
} from '../src/index.ts';
import { loadVector } from './helpers.ts';

type SigningVector = { payload_json: string; unsigned: UnsignedEnvelope; signing_input: string; signing_input_sha256_hex: string };
const vec = loadVector<SigningVector>('signing-input.json');

test('signing input matches vector byte for byte', () => {
  const si = signingInput(vec.unsigned);
  assert.equal(utf8Decode(si), vec.signing_input);
  assert.equal(createHash('sha256').update(si).digest('hex'), vec.signing_input_sha256_hex);
  assert.equal(utf8Decode(new TextEncoder().encode(JSON.stringify(decodePayload(vec.unsigned.payload)))), vec.payload_json);
});

test('signing input starts with the context label and has nine lines', () => {
  const lines = vec.signing_input.split('\n');
  assert.equal(lines[0], 'prc-signaling-v1');
  assert.equal(lines.length, 9);
  assert.equal(lines[8], vec.unsigned.payload);
});

test('sign, verify, and detect tampering of every field', async () => {
  const id = await generateIdentity();
  const other = await generateIdentity();
  const unsigned: UnsignedEnvelope = { ...vec.unsigned, from: id.deviceId, to: other.deviceId };
  const env = await signEnvelope(unsigned, id.privateKey);
  assert.equal(await verifyEnvelopeSignature(env, id.publicKey), true);
  assert.equal(await verifyEnvelopeSignature(env, other.publicKey), false);
  const mutations: Partial<UnsignedEnvelope>[] = [
    { v: 2 },
    { type: 'SESSION_AUTH' },
    { from: other.deviceId },
    { to: id.deviceId },
    { session: 'AAECAwQFBgcICQoLDA0ODw' },
    { seq: 2 },
    { ts: env.ts + 1 },
    { payload: encodePayload({ x: 1 }) },
  ];
  for (const m of mutations) assert.equal(await verifyEnvelopeSignature({ ...env, ...m }, id.publicKey), false, JSON.stringify(m));
  assert.equal(await verifyEnvelopeSignature({ ...env, sig: 'not base64url!' }, id.publicKey), false);
});

test('payload encoding round trips arbitrary unicode', () => {
  const value = { text: 'héllo wörld 👋', n: 1.5, nested: { a: [1, 2, 3] } };
  assert.deepEqual(decodePayload(encodePayload(value)), value);
  assert.throws(() => decodePayload('!!!'), /invalid_payload/);
});

test('EnvelopeSender numbers seq per recipient and session', async () => {
  const id = await generateIdentity();
  const s = new EnvelopeSender(id, () => 1000);
  const a1 = await s.build('SESSION_REQUEST', 'ab'.repeat(32), '', {});
  const a2 = await s.build('SESSION_AUTH', 'ab'.repeat(32), '', {});
  const b1 = await s.build('SDP_OFFER', 'ab'.repeat(32), 'AAECAwQFBgcICQoLDA0ODw', {});
  assert.equal(a1.seq, 1);
  assert.equal(a2.seq, 2);
  assert.equal(b1.seq, 1);
  assert.equal(a1.ts, 1000);
  assert.equal(a1.from, id.deviceId);
  assert.equal(await verifyEnvelopeSignature(b1, id.publicKey), true);
  s.forgetSession('ab'.repeat(32), '');
  assert.equal((await s.build('SESSION_REQUEST', 'ab'.repeat(32), '', {})).seq, 1);
});
