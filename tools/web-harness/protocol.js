// Browser port of the protocol essentials. Development harness only: the identity key is a plain
// 32-byte scalar persisted in localStorage, which a real controller must never do.
//
// Crypto comes from the audited pure-JavaScript noble libraries instead of WebCrypto, because
// browsers switch WebCrypto off on plain http:// pages that are not localhost, and the harness
// must load over plain http from other machines on the LAN (an https page could not open the
// agent's ws:// endpoint).
import { p256 } from '@noble/curves/p256.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { hmac } from '@noble/hashes/hmac.js';

const enc = new TextEncoder();
const dec = new TextDecoder();

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

export function unhex(s) {
  if (!/^([0-9a-f]{2})*$/.test(s)) throw new Error('invalid hex');
  return Uint8Array.from(s.match(/../g) ?? [], (h) => parseInt(h, 16));
}

export async function sha256Bytes(bytes) {
  return sha256(bytes);
}

export async function deviceIdFromPublicKey(raw) {
  if (raw.length !== 65 || raw[0] !== 4) throw new Error('invalid public key');
  return hex(sha256(raw));
}

export function fingerprint(deviceId) {
  const h = deviceId.slice(0, 12).toUpperCase();
  return `${h.slice(0, 4)}-${h.slice(4, 8)}-${h.slice(8, 12)}`;
}

/** Public keys are passed around as the raw 65-byte X9.63 point. This validates and returns it. */
export async function importPublicKey(raw) {
  if (raw.length !== 65 || raw[0] !== 4) throw new Error('invalid public key');
  p256.ProjectivePoint.fromHex(raw); // throws if the point is not on the curve
  return raw;
}

export async function loadIdentity(storageKey = 'prc.identity') {
  let priv = null;
  try {
    const stored = localStorage.getItem(storageKey);
    if (stored && /^[0-9a-f]{64}$/.test(stored)) priv = unhex(stored);
  } catch { priv = null; }
  if (!priv) {
    priv = p256.utils.randomPrivateKey();
    localStorage.setItem(storageKey, hex(priv));
  }
  const publicKeyRaw = p256.getPublicKey(priv, false);
  const deviceId = await deviceIdFromPublicKey(publicKeyRaw);
  return { privateKey: priv, publicKey: publicKeyRaw, publicKeyRaw, publicKeyB64: b64url(publicKeyRaw), deviceId, fingerprint: fingerprint(deviceId) };
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

/** ECDSA P-256 over SHA-256, raw r||s. Low-S is not required by the protocol, so verify accepts both. */
export function sign(privateKey, data) {
  return p256.sign(sha256(data), privateKey).toCompactRawBytes();
}

export function verify(publicKeyRaw, data, signature) {
  if (signature.length !== 64) return false;
  try {
    return p256.verify(signature, sha256(data), publicKeyRaw, { lowS: false });
  } catch {
    return false;
  }
}

export async function signEnvelope(unsigned, privateKey) {
  return { ...unsigned, sig: b64url(sign(privateKey, signingInput(unsigned))) };
}

export async function verifyEnvelope(env, publicKeyRaw) {
  try {
    const { sig, ...unsigned } = env;
    return verify(publicKeyRaw, signingInput(unsigned), unb64url(sig));
  } catch {
    return false;
  }
}

export async function pairingProof(codeBytes, pairingSessionId, controllerDeviceId) {
  return b64url(hmac(sha256, codeBytes, enc.encode(`${PAIRING_CONTEXT}\n${pairingSessionId}\n${controllerDeviceId}`)));
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
