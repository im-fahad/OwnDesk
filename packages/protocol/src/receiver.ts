/**
 * Receiver rules for signaling envelopes (spec section 6), applied in order.
 * Every failure is final for that message. The Swift and Kotlin implementations
 * mirror this class and share its test vectors.
 */
import { b64urlDecode, utf8Decode, utf8Encode } from './encoding.ts';
import {
  MAX_CLOCK_SKEW_MS,
  MAX_ENVELOPE_BYTES,
  SUPPORTED_VERSIONS,
  decodePayload,
  isSignalingType,
  verifyEnvelopeSignature,
  type Envelope,
} from './envelope.ts';
import { deviceIdFromPublicKey, importPublicKey } from './identity.ts';
import { validateEnvelopeShape, validateSignalingPayload } from './validate.ts';

export type RejectReason =
  | 'too_large'
  | 'malformed'
  | 'unsupported_version'
  | 'wrong_recipient'
  | 'unknown_type'
  | 'unknown_sender'
  | 'bad_signature'
  | 'stale_timestamp'
  | 'replayed'
  | 'invalid_payload';

export interface Accepted {
  ok: true;
  envelope: Envelope;
  payload: unknown;
  /** The key that verified the signature. For PAIR_REQUEST this is the key carried in the payload. */
  senderKey: CryptoKey;
}

export interface Rejected {
  ok: false;
  reason: RejectReason;
  detail?: string;
}

export type ReceiveResult = Accepted | Rejected;

export type KeyResolver = (deviceId: string) => Promise<CryptoKey | null> | CryptoKey | null;

export interface ReceiverOptions {
  selfDeviceId: string;
  /** Returns the public key of a trusted device, or null if unknown or revoked. */
  resolveKey: KeyResolver;
  now?: () => number;
  maxSkewMs?: number;
  /** Only the host while a pairing session is open. Controllers never accept PAIR_REQUEST. */
  acceptPairRequests?: boolean;
  supportedVersions?: readonly number[];
}

function reject(reason: RejectReason, detail?: string): Rejected {
  return detail === undefined ? { ok: false, reason } : { ok: false, reason, detail };
}

function seqKey(from: string, session: string): string {
  return `${from}|${session}`;
}

export class EnvelopeReceiver {
  readonly #self: string;
  readonly #resolveKey: KeyResolver;
  readonly #now: () => number;
  readonly #maxSkew: number;
  readonly #acceptPair: boolean;
  readonly #versions: readonly number[];
  readonly #lastSeq = new Map<string, number>();

  constructor(opts: ReceiverOptions) {
    this.#self = opts.selfDeviceId;
    this.#resolveKey = opts.resolveKey;
    this.#now = opts.now ?? (() => Date.now());
    this.#maxSkew = opts.maxSkewMs ?? MAX_CLOCK_SKEW_MS;
    this.#acceptPair = opts.acceptPairRequests ?? false;
    this.#versions = opts.supportedVersions ?? SUPPORTED_VERSIONS;
  }

  async receive(raw: string | Uint8Array): Promise<ReceiveResult> {
    const bytes = typeof raw === 'string' ? utf8Encode(raw) : raw;
    if (bytes.length > MAX_ENVELOPE_BYTES) return reject('too_large');

    let parsed: unknown;
    try {
      parsed = JSON.parse(utf8Decode(bytes));
    } catch {
      return reject('malformed', 'not json');
    }
    const shape = validateEnvelopeShape(parsed);
    if (!shape.valid) return reject('malformed', shape.errors[0]);
    const env = parsed as Envelope;

    if (!this.#versions.includes(env.v)) return reject('unsupported_version');
    if (env.to !== this.#self) return reject('wrong_recipient');
    if (!isSignalingType(env.type)) return reject('unknown_type');

    let key: CryptoKey | null;
    let payload: unknown = undefined;
    if (env.type === 'PAIR_REQUEST') {
      if (!this.#acceptPair) return reject('unknown_sender', 'pairing not open');
      try {
        payload = decodePayload(env.payload);
      } catch {
        return reject('invalid_payload');
      }
      const pv = validateSignalingPayload('PAIR_REQUEST', payload);
      if (!pv.valid) return reject('invalid_payload', pv.errors[0]);
      let raw: Uint8Array;
      let derivedId: string;
      try {
        raw = b64urlDecode((payload as { public_key: string }).public_key);
        derivedId = await deviceIdFromPublicKey(raw);
      } catch {
        return reject('invalid_payload', 'public_key');
      }
      if (derivedId !== env.from) return reject('unknown_sender', 'public_key does not match from');
      try {
        key = await importPublicKey(raw);
      } catch {
        return reject('invalid_payload', 'public_key');
      }
    } else {
      key = await this.#resolveKey(env.from);
      if (!key) return reject('unknown_sender');
    }

    if (!(await verifyEnvelopeSignature(env, key))) return reject('bad_signature');

    if (Math.abs(this.#now() - env.ts) > this.#maxSkew) return reject('stale_timestamp');

    const k = seqKey(env.from, env.session);
    if (env.seq <= (this.#lastSeq.get(k) ?? 0)) return reject('replayed');

    if (payload === undefined) {
      try {
        payload = decodePayload(env.payload);
      } catch {
        return reject('invalid_payload');
      }
      const pv = validateSignalingPayload(env.type, payload);
      if (!pv.valid) return reject('invalid_payload', pv.errors[0]);
    }

    // Record seq only for fully accepted messages. Replaying a rejected message gains nothing.
    this.#lastSeq.set(k, env.seq);
    return { ok: true, envelope: env, payload, senderKey: key };
  }

  /** Call on session cleanup so a future session with the same id (never expected) starts fresh. */
  forgetSession(from: string, session: string): void {
    this.#lastSeq.delete(seqKey(from, session));
  }

  /** Call on revocation. */
  forgetSender(from: string): void {
    for (const k of [...this.#lastSeq.keys()]) if (k.startsWith(`${from}|`)) this.#lastSeq.delete(k);
  }
}
