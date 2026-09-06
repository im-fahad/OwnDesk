import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateIdentity, importPublicKeyB64, serverAuthSigningInput, signServerAuth, utf8Decode, verifyServerAuth } from '../src/index.ts';
import { loadVector } from './helpers.ts';

type ServerAuthVector = { nonce: string; origin: string; device_id: string; public_key: string; signing_input: string; signature: string; wrong_origin: string };
const vec = loadVector<ServerAuthVector>('server-auth.json');

test('server auth signing input and vector signature', async () => {
  assert.equal(utf8Decode(serverAuthSigningInput(vec.nonce, vec.origin, vec.device_id)), vec.signing_input);
  const pub = await importPublicKeyB64(vec.public_key);
  assert.equal(await verifyServerAuth(pub, vec.nonce, vec.origin, vec.device_id, vec.signature), true);
  assert.equal(await verifyServerAuth(pub, vec.nonce, vec.wrong_origin, vec.device_id, vec.signature), false, 'origin binding');
  assert.equal(await verifyServerAuth(pub, vec.nonce.replace(/^./, 'B'), vec.origin, vec.device_id, vec.signature), false, 'nonce binding');
  assert.equal(await verifyServerAuth(pub, vec.nonce, vec.origin, 'ef'.repeat(32), vec.signature), false, 'device binding');
});

test('a fresh identity can authenticate', async () => {
  const id = await generateIdentity();
  const sig = await signServerAuth(id, vec.nonce, vec.origin);
  assert.equal(await verifyServerAuth(id.publicKey, vec.nonce, vec.origin, id.deviceId, sig), true);
});
