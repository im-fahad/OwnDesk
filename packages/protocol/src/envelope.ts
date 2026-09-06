/**
 * Signaling envelope (spec section 6). Every control-plane message between two devices,
 * over the LAN endpoint or relayed by the rendezvous server, is one of these.
 */
import { b64urlDecode, b64urlEncode, utf8Decode, utf8Encode } from './encoding.ts';
import { ProtocolError } from './errors.ts';
import { sign, verify, type Identity } from './identity.ts';

export const PROTOCOL_VERSION = 1;
export const SUPPORTED_VERSIONS: readonly number[] = [1];
export const SIGNALING_CONTEXT = 'prc-signaling-v1';
export const MAX_ENVELOPE_BYTES = 65536;
export const MAX_CLOCK_SKEW_MS = 300_000;

export const SIGNALING_TYPES = [
  'PAIR_REQUEST',
  'PAIR_RESULT',
  'SESSION_REQUEST',
  'SESSION_CHALLENGE',
  'SESSION_AUTH',
  'SESSION_ACCEPT',
  'SESSION_REJECT',
  'SDP_OFFER',
  'SDP_ANSWER',
  'ICE_CANDIDATE',
  'SESSION_RESUME',
  'SESSION_END',
] as const;
export type SignalingType = (typeof SIGNALING_TYPES)[number];

export function isSignalingType(t: string): t is SignalingType {
  return (SIGNALING_TYPES as readonly string[]).includes(t);
}

export interface UnsignedEnvelope {
  v: number;
  type: string;
  from: string;
  to: string;
  /** Empty string before a session exists (pairing, SESSION_REQUEST). */
  session: string;
  /** Starts at 1 and increases by 1 per sender per session. */
  seq: number;
  /** Unix milliseconds. */
  ts: number;
  /** base64url of the exact UTF-8 JSON bytes of the payload object. */
  payload: string;
}

export interface Envelope extends UnsignedEnvelope {
  sig: string;
}

/** The bytes that are signed. Fields joined by newline after the context label. */
export function signingInput(e: UnsignedEnvelope): Uint8Array {
  const s = [SIGNALING_CONTEXT, String(e.v), e.type, e.from, e.to, e.session, String(e.seq), String(e.ts), e.payload].join('\n');
  return utf8Encode(s);
}

export function encodePayload(value: unknown): string {
  return b64urlEncode(utf8Encode(JSON.stringify(value)));
}

export function decodePayload(payload: string): unknown {
  try {
    return JSON.parse(utf8Decode(b64urlDecode(payload)));
  } catch {
    throw new ProtocolError('invalid_payload');
  }
}

export async function signEnvelope(unsigned: UnsignedEnvelope, privateKey: CryptoKey): Promise<Envelope> {
  const sig = await sign(privateKey, signingInput(unsigned));
  return { ...unsigned, sig: b64urlEncode(sig) };
}

export async function verifyEnvelopeSignature(e: Envelope, publicKey: CryptoKey): Promise<boolean> {
  let sig: Uint8Array;
  try {
    sig = b64urlDecode(e.sig);
  } catch {
    return false;
  }
  const { sig: _sig, ...unsigned } = e;
  return verify(publicKey, signingInput(unsigned), sig);
}

export function serializeEnvelope(e: Envelope): string {
  return JSON.stringify(e);
}

/** Builds and signs outgoing envelopes, tracking `seq` per (recipient, session). */
export class EnvelopeSender {
  readonly #identity: Identity;
  readonly #seq = new Map<string, number>();
  readonly #now: () => number;

  constructor(identity: Identity, now: () => number = () => Date.now()) {
    this.#identity = identity;
    this.#now = now;
  }

  get deviceId(): string {
    return this.#identity.deviceId;
  }

  async build(type: SignalingType, to: string, session: string, payload: unknown): Promise<Envelope> {
    const key = `${to}|${session}`;
    const seq = (this.#seq.get(key) ?? 0) + 1;
    this.#seq.set(key, seq);
    return signEnvelope(
      { v: PROTOCOL_VERSION, type, from: this.#identity.deviceId, to, session, seq, ts: this.#now(), payload: encodePayload(payload) },
      this.#identity.privateKey,
    );
  }

  forgetSession(to: string, session: string): void {
    this.#seq.delete(`${to}|${session}`);
  }
}
