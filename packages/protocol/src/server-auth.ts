/** Authentication of a device to the rendezvous server (spec section 11.1). */
import { b64urlDecode, b64urlEncode, utf8Encode } from './encoding.ts';
import { sign, verify, type Identity } from './identity.ts';

export const SERVER_AUTH_CONTEXT = 'prc-server-auth-v1';
export const SERVER_NONCE_BYTES = 32;
export const SERVER_NONCE_TTL_MS = 60_000;

export function serverAuthSigningInput(nonce: string, origin: string, deviceId: string): Uint8Array {
  return utf8Encode(`${SERVER_AUTH_CONTEXT}\n${nonce}\n${origin}\n${deviceId}`);
}

export async function signServerAuth(identity: Identity, nonce: string, origin: string): Promise<string> {
  return b64urlEncode(await sign(identity.privateKey, serverAuthSigningInput(nonce, origin, identity.deviceId)));
}

export async function verifyServerAuth(publicKey: CryptoKey, nonce: string, origin: string, deviceId: string, sigB64: string): Promise<boolean> {
  let sig: Uint8Array;
  try {
    sig = b64urlDecode(sigB64);
  } catch {
    return false;
  }
  return verify(publicKey, serverAuthSigningInput(nonce, origin, deviceId), sig);
}
