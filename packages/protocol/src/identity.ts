/**
 * Device identity: ECDSA P-256 with SHA-256.
 *
 * Encodings (spec section 5.2):
 *   public key  = 65-byte X9.63 uncompressed point, base64url
 *   device id   = lowercase hex SHA-256 of those 65 bytes
 *   fingerprint = first 12 hex chars of the device id as XXXX-XXXX-XXXX, upper case
 *   signature   = raw r||s, 64 bytes, base64url
 */
import { b64urlDecode, b64urlEncode, hexEncode, toArrayBuffer } from './encoding.ts';
import { ProtocolError } from './errors.ts';

const subtle = globalThis.crypto.subtle;

export const ECDSA_KEY_PARAMS = { name: 'ECDSA', namedCurve: 'P-256' } as const;
export const ECDSA_SIGN_PARAMS = { name: 'ECDSA', hash: 'SHA-256' } as const;
export const PUBLIC_KEY_BYTES = 65;
export const SIGNATURE_BYTES = 64;
export const DEVICE_ID_PATTERN = /^[0-9a-f]{64}$/;

export interface Identity {
  readonly privateKey: CryptoKey;
  readonly publicKey: CryptoKey;
  readonly publicKeyRaw: Uint8Array;
  readonly publicKeyB64: string;
  readonly deviceId: string;
}

export async function generateIdentity(): Promise<Identity> {
  const kp = (await subtle.generateKey(ECDSA_KEY_PARAMS, false, ['sign', 'verify'])) as CryptoKeyPair;
  return identityFromKeyPair(kp);
}

/** Test and tooling only. Production keys live in hardware key stores and are never exportable. */
export async function importIdentityFromJwk(privateJwk: JsonWebKey): Promise<Identity> {
  const { d: _d, key_ops: _ops, ...rest } = privateJwk;
  const privateKey = await subtle.importKey('jwk', { ...privateJwk, key_ops: ['sign'] }, ECDSA_KEY_PARAMS, false, ['sign']);
  const publicKey = await subtle.importKey('jwk', { ...rest, key_ops: ['verify'] }, ECDSA_KEY_PARAMS, true, ['verify']);
  return identityFromKeyPair({ privateKey, publicKey });
}

async function identityFromKeyPair(kp: CryptoKeyPair): Promise<Identity> {
  const publicKeyRaw = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
  return {
    privateKey: kp.privateKey,
    publicKey: kp.publicKey,
    publicKeyRaw,
    publicKeyB64: b64urlEncode(publicKeyRaw),
    deviceId: await deviceIdFromPublicKey(publicKeyRaw),
  };
}

export function assertPublicKeyRaw(raw: Uint8Array): void {
  if (raw.length !== PUBLIC_KEY_BYTES || raw[0] !== 0x04) throw new ProtocolError('invalid_public_key');
}

export async function deviceIdFromPublicKey(raw: Uint8Array): Promise<string> {
  assertPublicKeyRaw(raw);
  return hexEncode(new Uint8Array(await subtle.digest('SHA-256', toArrayBuffer(raw))));
}

export async function importPublicKey(raw: Uint8Array): Promise<CryptoKey> {
  assertPublicKeyRaw(raw);
  try {
    return await subtle.importKey('raw', toArrayBuffer(raw), ECDSA_KEY_PARAMS, true, ['verify']);
  } catch {
    throw new ProtocolError('invalid_public_key');
  }
}

export async function importPublicKeyB64(b64: string): Promise<CryptoKey> {
  return importPublicKey(b64urlDecode(b64));
}

export function fingerprint(deviceId: string): string {
  if (!DEVICE_ID_PATTERN.test(deviceId)) throw new ProtocolError('invalid_device_id');
  const h = deviceId.slice(0, 12).toUpperCase();
  return `${h.slice(0, 4)}-${h.slice(4, 8)}-${h.slice(8, 12)}`;
}

export async function sign(privateKey: CryptoKey, data: Uint8Array): Promise<Uint8Array> {
  const sig = new Uint8Array(await subtle.sign(ECDSA_SIGN_PARAMS, privateKey, toArrayBuffer(data)));
  if (sig.length !== SIGNATURE_BYTES) throw new ProtocolError('bad_signature_length');
  return sig;
}

export async function verify(publicKey: CryptoKey, data: Uint8Array, signature: Uint8Array): Promise<boolean> {
  if (signature.length !== SIGNATURE_BYTES) return false;
  try {
    return await subtle.verify(ECDSA_SIGN_PARAMS, publicKey, toArrayBuffer(signature), toArrayBuffer(data));
  } catch {
    return false;
  }
}
