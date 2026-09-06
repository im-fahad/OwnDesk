/**
 * Generates ../vectors/*.json. Run with `npm run vectors`.
 *
 * Test keys in vectors/test-keys.json are created once and reused so device ids stay stable.
 * They are TEST KEYS ONLY and must never be used by a real device.
 * ECDSA signatures are randomized, so signature values change on every run while everything
 * they sign stays identical. Other implementations verify them; they never compare bytes.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  PROTOCOL_VERSION,
  b64urlEncode,
  encodePayload,
  fingerprint,
  hexEncode,
  importIdentityFromJwk,
  pairingProof,
  pairingProofInput,
  serverAuthSigningInput,
  signEnvelope,
  signServerAuth,
  signingInput,
  toArrayBuffer,
  turnCredentials,
  utf8Decode,
  type Envelope,
  type Identity,
  type UnsignedEnvelope,
} from '../src/index.ts';

const VEC = join(import.meta.dirname, '..', 'vectors');
mkdirSync(VEC, { recursive: true });

const NOW = 1757203200000;
const subtle = globalThis.crypto.subtle;

type KeyFile = { warning: string; keys: Record<string, JsonWebKey> };
const keyPath = join(VEC, 'test-keys.json');
let keyFile: KeyFile;
if (existsSync(keyPath)) {
  keyFile = JSON.parse(readFileSync(keyPath, 'utf8')) as KeyFile;
} else {
  keyFile = { warning: 'TEST KEYS ONLY. Never load these into a real device.', keys: {} };
  for (const name of ['host', 'controller', 'stranger']) {
    const kp = (await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    keyFile.keys[name] = await subtle.exportKey('jwk', kp.privateKey);
  }
  writeFileSync(keyPath, JSON.stringify(keyFile, null, 2) + '\n');
}

const ids: Record<string, Identity> = {};
for (const [name, jwk] of Object.entries(keyFile.keys)) ids[name] = await importIdentityFromJwk(jwk);
const host = ids.host!;
const controller = ids.controller!;
const stranger = ids.stranger!;

function write(name: string, value: unknown): void {
  writeFileSync(join(VEC, name), JSON.stringify(value, null, 2) + '\n');
  console.log('wrote', name);
}

// 1. identity ------------------------------------------------------------------------------
write('identity.json', {
  description: 'Public key encoding, device id derivation, and fingerprint display.',
  keys: Object.fromEntries(
    Object.entries(ids).map(([n, id]) => [n, { public_key: id.publicKeyB64, device_id: id.deviceId, fingerprint: fingerprint(id.deviceId) }]),
  ),
  invalid_public_keys: [
    { public_key: b64urlEncode(new Uint8Array(64).fill(4)), why: '64 bytes' },
    { public_key: b64urlEncode(new Uint8Array([0x02, ...new Uint8Array(64)])), why: 'compressed prefix' },
    { public_key: b64urlEncode(new Uint8Array(66).fill(4)), why: '66 bytes' },
  ],
});

// 2. signing input -------------------------------------------------------------------------
const sessionRequestPayload = {
  client_nonce: 'AAECAwQFBgcICQoLDA0ODw',
  versions: [1],
  path: 'lan',
  capabilities: { codecs: ['H264'], max_height: 1080, max_fps: 60 },
};
const unsigned: UnsignedEnvelope = {
  v: PROTOCOL_VERSION,
  type: 'SESSION_REQUEST',
  from: controller.deviceId,
  to: host.deviceId,
  session: '',
  seq: 1,
  ts: NOW,
  payload: encodePayload(sessionRequestPayload),
};
const si = signingInput(unsigned);
write('signing-input.json', {
  description: 'The exact bytes signed for an envelope. Implementations must reproduce signing_input byte for byte.',
  payload_json: JSON.stringify(sessionRequestPayload),
  unsigned,
  signing_input: utf8Decode(si),
  signing_input_sha256_hex: hexEncode(new Uint8Array(await subtle.digest('SHA-256', toArrayBuffer(si)))),
});

// 3. receiver cases ------------------------------------------------------------------------
async function env(id: Identity, over: Partial<UnsignedEnvelope>, payload: unknown): Promise<Envelope> {
  return signEnvelope(
    { v: PROTOCOL_VERSION, type: 'SESSION_REQUEST', from: id.deviceId, to: host.deviceId, session: '', seq: 1, ts: NOW, payload: encodePayload(payload), ...over },
    id.privateKey,
  );
}

const valid1 = await env(controller, {}, sessionRequestPayload);
const tampered = { ...(await env(controller, { seq: 2 }, sessionRequestPayload)), payload: encodePayload({ ...sessionRequestPayload, path: 'cloud' }) };
const pairPayloadFor = (pubB64: string) => ({
  public_key: pubB64,
  device_name: 'Test Phone',
  device_type: 'android',
  pairing_session_id: 'EBESExQVFhcYGRobHB0eHw',
  proof: b64urlEncode(new Uint8Array(32).fill(7)),
});
const SESSION_ID = 'ICEiIyQlJicoKSorLC0uLw';

const cases: { name: string; envelope: Envelope; expect: string }[] = [
  { name: 'valid SESSION_REQUEST seq 1', envelope: valid1, expect: 'ok' },
  { name: 'exact replay of seq 1', envelope: valid1, expect: 'replayed' },
  { name: 'payload changed after signing', envelope: tampered, expect: 'bad_signature' },
  { name: 'timestamp 10 minutes old', envelope: await env(controller, { seq: 3, ts: NOW - 600_000 }, sessionRequestPayload), expect: 'stale_timestamp' },
  { name: 'addressed to another device', envelope: await env(controller, { seq: 3, to: controller.deviceId }, sessionRequestPayload), expect: 'wrong_recipient' },
  { name: 'unknown sender with valid signature', envelope: await env(stranger, {}, sessionRequestPayload), expect: 'unknown_sender' },
  { name: 'unsupported version 2', envelope: await env(controller, { seq: 3, v: 2 }, sessionRequestPayload), expect: 'unsupported_version' },
  { name: 'unknown type', envelope: await env(controller, { seq: 3, type: 'FOO' }, sessionRequestPayload), expect: 'unknown_type' },
  { name: 'valid signature, payload missing client_nonce', envelope: await env(controller, { seq: 3 }, { versions: [1], path: 'lan', capabilities: sessionRequestPayload.capabilities }), expect: 'invalid_payload' },
  { name: 'PAIR_REQUEST self-certified by unknown device', envelope: await env(stranger, { type: 'PAIR_REQUEST' }, pairPayloadFor(stranger.publicKeyB64)), expect: 'ok' },
  { name: 'PAIR_REQUEST whose public_key does not match from', envelope: await env(stranger, { type: 'PAIR_REQUEST', seq: 2 }, pairPayloadFor(controller.publicKeyB64)), expect: 'unknown_sender' },
  { name: 'seq 3 accepted after rejected attempts', envelope: await env(controller, { seq: 3 }, sessionRequestPayload), expect: 'ok' },
  { name: 'seq 2 after seq 3 is a replay', envelope: await env(controller, { seq: 2 }, sessionRequestPayload), expect: 'replayed' },
  { name: 'signature field wrong length', envelope: { ...(await env(controller, { seq: 4 }, sessionRequestPayload)), sig: 'AAAAAAAAAA' }, expect: 'malformed' },
  { name: 'seq restarts at 1 inside a session id', envelope: await env(controller, { type: 'SDP_OFFER', session: SESSION_ID }, { sdp: 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n', ice_restart: false }), expect: 'ok' },
  { name: 'host-signed message claiming to be from controller', envelope: await signEnvelope({ ...unsigned, seq: 5 }, host.privateKey), expect: 'bad_signature' },
];

write('envelopes.json', {
  description: 'Receiver rule cases, processed in order by one receiver instance with the given clock and trust set.',
  receiver: {
    self_device_id: host.deviceId,
    trusted: { [controller.deviceId]: controller.publicKeyB64 },
    now_ms: NOW,
    accept_pair_requests: true,
  },
  cases,
});

// 4. pairing proof -------------------------------------------------------------------------
const pairingCode = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
const pairingSessionId = 'EBESExQVFhcYGRobHB0eHw';
write('pairing.json', {
  description: 'HMAC-SHA256 proof of QR possession. Deterministic.',
  pairing_code: b64urlEncode(pairingCode),
  pairing_session_id: pairingSessionId,
  controller_device_id: controller.deviceId,
  proof_input: utf8Decode(pairingProofInput(pairingSessionId, controller.deviceId)),
  proof: await pairingProof(pairingCode, pairingSessionId, controller.deviceId),
  wrong_code: b64urlEncode(new Uint8Array(16).fill(1)),
});

// 5. server auth ---------------------------------------------------------------------------
const nonce = b64urlEncode(new Uint8Array(32).map((_, i) => i));
const origin = 'prc.example.com';
write('server-auth.json', {
  description: 'Signature a device presents to the rendezvous server. Verify with public_key; must fail for wrong_origin.',
  nonce,
  origin,
  device_id: controller.deviceId,
  public_key: controller.publicKeyB64,
  signing_input: utf8Decode(serverAuthSigningInput(nonce, origin, controller.deviceId)),
  signature: await signServerAuth(controller, nonce, origin),
  wrong_origin: 'evil.example.com',
});

// 6. TURN ----------------------------------------------------------------------------------
const turn = await turnCredentials('test-turn-secret', controller.deviceId, NOW, 7200);
write('turn.json', {
  description: "coturn use-auth-secret credentials: username = expiry:device_id, credential = base64(HMAC-SHA1(secret, username)).",
  secret: 'test-turn-secret',
  device_id: controller.deviceId,
  now_ms: NOW,
  ttl_s: 7200,
  ...turn,
});
