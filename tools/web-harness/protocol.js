// Browser port of the protocol essentials. Development harness only: the identity key is an
// extractable WebCrypto key persisted as JWK in localStorage, which a real controller must never do.

const enc = new TextEncoder();
const dec = new TextDecoder();
const subtle = crypto.subtle;

export const PROTOCOL_VERSION = 1;
export const SIGNALING_CONTEXT = 'prc-signaling-v1';
export const PAIRING_CONTEXT = 'prc-pairing-v1';
export const MAX_SKEW_MS = 300_000;

export function b64url(bytes) {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function unb64url(s) {
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) throw new Error('invalid base64url');
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function hex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function sha256(bytes) {
  return new Uint8Array(await subtle.digest('SHA-256', bytes));
}

export async function deviceIdFromPublicKey(raw) {
  if (raw.length !== 65 || raw[0] !== 4) throw new Error('invalid public key');
  return hex(await sha256(raw));
}

export function fingerprint(deviceId) {
  const h = deviceId.slice(0, 12).toUpperCase();
  return `${h.slice(0, 4)}-${h.slice(4, 8)}-${h.slice(8, 12)}`;
}

const KEY_PARAMS = { name: 'ECDSA', namedCurve: 'P-256' };
const SIGN_PARAMS = { name: 'ECDSA', hash: 'SHA-256' };

export async function importPublicKey(raw) {
  return subtle.importKey('raw', raw, KEY_PARAMS, true, ['verify']);
}

export async function loadIdentity(storageKey = 'prc.identity') {
  let jwk = null;
  try { jwk = JSON.parse(localStorage.getItem(storageKey) || 'null'); } catch { jwk = null; }
  if (!jwk) {
    const kp = await subtle.generateKey(KEY_PARAMS, true, ['sign', 'verify']);
    jwk = await subtle.exportKey('jwk', kp.privateKey);
    localStorage.setItem(storageKey, JSON.stringify(jwk));
  }
  const { d, key_ops, ...pub } = jwk;
  const privateKey = await subtle.importKey('jwk', { ...jwk, key_ops: ['sign'] }, KEY_PARAMS, false, ['sign']);
  const publicKey = await subtle.importKey('jwk', { ...pub, key_ops: ['verify'] }, KEY_PARAMS, true, ['verify']);
  const publicKeyRaw = new Uint8Array(await subtle.exportKey('raw', publicKey));
  const deviceId = await deviceIdFromPublicKey(publicKeyRaw);
  return { privateKey, publicKey, publicKeyRaw, publicKeyB64: b64url(publicKeyRaw), deviceId, fingerprint: fingerprint(deviceId) };
}

export function resetIdentity(storageKey = 'prc.identity') {
  localStorage.removeItem(storageKey);
}

export function signingInput(e) {
  return enc.encode([SIGNALING_CONTEXT, String(e.v), e.type, e.from, e.to, e.session, String(e.seq), String(e.ts), e.payload].join('\n'));
}

export function encodePayload(value) {
  return b64url(enc.encode(JSON.stringify(value)));
}

export function decodePayload(payload) {
  return JSON.parse(dec.decode(unb64url(payload)));
}

export async function signEnvelope(unsigned, privateKey) {
  const sig = new Uint8Array(await subtle.sign(SIGN_PARAMS, privateKey, signingInput(unsigned)));
  return { ...unsigned, sig: b64url(sig) };
}

export async function verifyEnvelope(env, publicKey) {
  try {
    const { sig, ...unsigned } = env;
    const bytes = unb64url(sig);
    if (bytes.length !== 64) return false;
    return await subtle.verify(SIGN_PARAMS, publicKey, bytes, signingInput(unsigned));
  } catch {
    return false;
  }
}

export async function pairingProof(codeBytes, pairingSessionId, controllerDeviceId) {
  const key = await subtle.importKey('raw', codeBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await subtle.sign('HMAC', key, enc.encode(`${PAIRING_CONTEXT}\n${pairingSessionId}\n${controllerDeviceId}`)));
  return b64url(mac);
}

export function randomB64url(n = 16) {
  const bytes = new Uint8Array(n);
  crypto.getRandomValues(bytes);
  return b64url(bytes);
}

/** Builds signed envelopes with per-(recipient, session) sequence numbers. */
export class Sender {
  #identity;
  #seq = new Map();
  constructor(identity) { this.#identity = identity; }
  async build(type, to, session, payload) {
    const key = `${to}|${session}`;
    const seq = (this.#seq.get(key) ?? 0) + 1;
    this.#seq.set(key, seq);
    return signEnvelope({ v: PROTOCOL_VERSION, type, from: this.#identity.deviceId, to, session, seq, ts: Date.now(), payload: encodePayload(payload) }, this.#identity.privateKey);
  }
  forget(to, session) { this.#seq.delete(`${to}|${session}`); }
}

/** Verifies inbound envelopes: recipient, known key, signature, clock skew, replay. */
export class Receiver {
  #self; #resolveKey; #lastSeq = new Map();
  constructor(selfDeviceId, resolveKey) { this.#self = selfDeviceId; this.#resolveKey = resolveKey; }
  async receive(text) {
    let env;
    try { env = JSON.parse(text); } catch { return { ok: false, reason: 'malformed' }; }
    if (!env || typeof env !== 'object' || env.v !== PROTOCOL_VERSION) return { ok: false, reason: 'unsupported_version' };
    if (env.to !== this.#self) return { ok: false, reason: 'wrong_recipient' };
    const key = await this.#resolveKey(env.from, env);
    if (!key) return { ok: false, reason: 'unknown_sender' };
    if (!(await verifyEnvelope(env, key))) return { ok: false, reason: 'bad_signature' };
    if (Math.abs(Date.now() - env.ts) > MAX_SKEW_MS) return { ok: false, reason: 'stale_timestamp' };
    const k = `${env.from}|${env.session}`;
    if (env.seq <= (this.#lastSeq.get(k) ?? 0)) return { ok: false, reason: 'replayed' };
    let payload;
    try { payload = decodePayload(env.payload); } catch { return { ok: false, reason: 'invalid_payload' }; }
    this.#lastSeq.set(k, env.seq);
    // A reply in the empty namespace ends an attempt: both sides reset (spec section 6).
    if (env.session === '') this.#lastSeq.delete(k);
    return { ok: true, envelope: env, payload };
  }
  forgetSession(from, session) { this.#lastSeq.delete(`${from}|${session}`); }
}
