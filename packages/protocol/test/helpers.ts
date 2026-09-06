import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export function loadVector<T = unknown>(name: string): T {
  return JSON.parse(readFileSync(join(import.meta.dirname, '..', 'vectors', name), 'utf8')) as T;
}

/** Sample values that satisfy the common schema patterns. */
export const SAMPLE = {
  bytes16: 'AAECAwQFBgcICQoLDA0ODw',
  bytes32: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  deviceId: 'ab'.repeat(32),
  otherDeviceId: 'cd'.repeat(32),
  publicKey: 'A'.repeat(87),
  signature: 'B'.repeat(86),
  display: { display_id: 'main', width_px: 1920, height_px: 1080, scale: 2 },
} as const;
