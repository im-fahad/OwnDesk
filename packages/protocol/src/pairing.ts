/** Pairing (spec section 7): QR payload, proof of QR possession, and limits. */
import { b64urlEncode, constantTimeEqual, randomBytes, toArrayBuffer, utf8Encode } from './encoding.ts';

const subtle = globalThis.crypto.subtle;

export const PAIRING_CONTEXT = 'prc-pairing-v1';
export const PAIRING_TTL_MS = 120_000;
export const PAIRING_MAX_FAILED_PROOFS = 3;
export const PAIRING_SECRET_BYTES = 16;

export interface QrPayload {
  v: number;
  kind: 'prc-pair';
  host_device_id: string;
  host_key_hash: string;
  host_name: string;
  addresses: string[];
  rendezvous_url: string | null;
  pairing_session_id: string;
  pairing_code: string;
  expires_at: number;
}

export interface PairingSecrets {
  pairingSessionId: string;
  pairingCode: string;
  pairingCodeBytes: Uint8Array;
}

export function generatePairingSecrets(): PairingSecrets {
  const code = randomBytes(PAIRING_SECRET_BYTES);
  return { pairingSessionId: b64urlEncode(randomBytes(PAIRING_SECRET_BYTES)), pairingCode: b64urlEncode(code), pairingCodeBytes: code };
}

export function pairingProofInput(pairingSessionId: string, controllerDeviceId: string): Uint8Array {
  return utf8Encode(`${PAIRING_CONTEXT}\n${pairingSessionId}\n${controllerDeviceId}`);
}

export async function pairingProof(pairingCode: Uint8Array, pairingSessionId: string, controllerDeviceId: string): Promise<string> {
  const key = await subtle.importKey('raw', toArrayBuffer(pairingCode), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await subtle.sign('HMAC', key, toArrayBuffer(pairingProofInput(pairingSessionId, controllerDeviceId))));
  return b64urlEncode(mac);
}

export async function verifyPairingProof(
  pairingCode: Uint8Array,
  pairingSessionId: string,
  controllerDeviceId: string,
  proof: string,
): Promise<boolean> {
  const expected = await pairingProof(pairingCode, pairingSessionId, controllerDeviceId);
  return constantTimeEqual(utf8Encode(expected), utf8Encode(proof));
}

export function buildQrPayload(args: {
  hostDeviceId: string;
  hostName: string;
  addresses: string[];
  rendezvousUrl: string | null;
  secrets: PairingSecrets;
  now: number;
}): QrPayload {
  return {
    v: 1,
    kind: 'prc-pair',
    host_device_id: args.hostDeviceId,
    host_key_hash: args.hostDeviceId,
    host_name: args.hostName,
    addresses: args.addresses,
    rendezvous_url: args.rendezvousUrl,
    pairing_session_id: args.secrets.pairingSessionId,
    pairing_code: args.secrets.pairingCode,
    expires_at: args.now + PAIRING_TTL_MS,
  };
}
