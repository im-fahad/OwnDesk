import { test } from 'node:test';
import assert from 'node:assert/strict';
import { b64urlDecode, deviceIdFromPublicKey, fingerprint, generateIdentity, importPublicKeyB64, sign, utf8Encode, verify } from '../src/index.ts';
import { loadVector } from './helpers.ts';

type IdentityVector = {
  keys: Record<string, { public_key: string; device_id: string; fingerprint: string }>;
  invalid_public_keys: { public_key: string; why: string }[];
};
const vec = loadVector<IdentityVector>('identity.json');

test('device id and fingerprint match vectors', async () => {
  for (const [name, k] of Object.entries(vec.keys)) {
    const raw = b64urlDecode(k.public_key);
    assert.equal(raw.length, 65, name);
    assert.equal(await deviceIdFromPublicKey(raw), k.device_id, name);
    assert.equal(fingerprint(k.device_id), k.fingerprint, name);
    assert.match(k.fingerprint, /^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/);
  }
});

test('invalid public keys are rejected', async () => {
  for (const bad of vec.invalid_public_keys) {
    await assert.rejects(() => deviceIdFromPublicKey(b64urlDecode(bad.public_key)), /invalid_public_key/, bad.why);
    await assert.rejects(() => importPublicKeyB64(bad.public_key), /invalid_public_key/, bad.why);
  }
});

test('sign and verify round trip, tamper and wrong key fail', async () => {
  const a = await generateIdentity();
  const b = await generateIdentity();
  const data = utf8Encode('hello');
  const sig = await sign(a.privateKey, data);
  assert.equal(sig.length, 64);
  assert.equal(await verify(a.publicKey, data, sig), true);
  assert.equal(await verify(a.publicKey, utf8Encode('hellp'), sig), false);
  assert.equal(await verify(b.publicKey, data, sig), false);
  assert.equal(await verify(a.publicKey, data, sig.slice(0, 63)), false);
  const imported = await importPublicKeyB64(a.publicKeyB64);
  assert.equal(await verify(imported, data, sig), true);
});

test('fingerprint rejects malformed ids', () => {
  assert.throws(() => fingerprint('xyz'), /invalid_device_id/);
});
