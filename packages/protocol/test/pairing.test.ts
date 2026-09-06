import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import {
  PAIRING_TTL_MS,
  b64urlDecode,
  buildQrPayload,
  generatePairingSecrets,
  pairingProof,
  pairingProofInput,
  utf8Decode,
  validateQrPayload,
  verifyPairingProof,
} from '../src/index.ts';
import { loadVector } from './helpers.ts';

type PairingVector = { pairing_code: string; pairing_session_id: string; controller_device_id: string; proof_input: string; proof: string; wrong_code: string };
const vec = loadVector<PairingVector>('pairing.json');

test('pairing proof matches vector and an independent HMAC', async () => {
  const code = b64urlDecode(vec.pairing_code);
  assert.equal(utf8Decode(pairingProofInput(vec.pairing_session_id, vec.controller_device_id)), vec.proof_input);
  assert.equal(await pairingProof(code, vec.pairing_session_id, vec.controller_device_id), vec.proof);
  const independent = createHmac('sha256', code).update(vec.proof_input).digest('base64url');
  assert.equal(independent, vec.proof);
});

test('proof verification accepts the right code and rejects the wrong one', async () => {
  assert.equal(await verifyPairingProof(b64urlDecode(vec.pairing_code), vec.pairing_session_id, vec.controller_device_id, vec.proof), true);
  assert.equal(await verifyPairingProof(b64urlDecode(vec.wrong_code), vec.pairing_session_id, vec.controller_device_id, vec.proof), false);
  assert.equal(await verifyPairingProof(b64urlDecode(vec.pairing_code), vec.pairing_session_id, 'ef'.repeat(32), vec.proof), false);
  assert.equal(await verifyPairingProof(b64urlDecode(vec.pairing_code), vec.pairing_session_id, vec.controller_device_id, vec.proof.slice(1)), false);
});

test('generated QR payload validates against its schema and expires in 120 s', () => {
  const secrets = generatePairingSecrets();
  assert.equal(secrets.pairingCodeBytes.length, 16);
  const qr = buildQrPayload({
    hostDeviceId: vec.controller_device_id,
    hostName: 'Mac Mini M4',
    addresses: ['192.168.1.20:47500'],
    rendezvousUrl: 'wss://prc.example.com/ws',
    secrets,
    now: 1_000_000,
  });
  assert.deepEqual(validateQrPayload(qr), { valid: true, errors: [] });
  assert.equal(qr.expires_at - 1_000_000, PAIRING_TTL_MS);
  assert.equal(validateQrPayload({ ...qr, rendezvous_url: 'http://not-ws' }).valid, false);
  assert.equal(validateQrPayload({ ...qr, pairing_code: 'short' }).valid, false);
});
