/** Time-limited TURN credentials in coturn's use-auth-secret form (spec section 11.1). */
import { b64Encode, toArrayBuffer, utf8Encode } from './encoding.ts';

const subtle = globalThis.crypto.subtle;

export const TURN_CREDENTIAL_TTL_S = 7200;

export interface TurnCredentials {
  username: string;
  credential: string;
  /** Unix milliseconds. */
  expires_at: number;
}

export async function turnCredentials(secret: string, deviceId: string, nowMs: number, ttlS: number = TURN_CREDENTIAL_TTL_S): Promise<TurnCredentials> {
  const expiry = Math.floor(nowMs / 1000) + ttlS;
  const username = `${expiry}:${deviceId}`;
  const key = await subtle.importKey('raw', toArrayBuffer(utf8Encode(secret)), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const mac = new Uint8Array(await subtle.sign('HMAC', key, toArrayBuffer(utf8Encode(username))));
  return { username, credential: b64Encode(mac), expires_at: expiry * 1000 };
}
