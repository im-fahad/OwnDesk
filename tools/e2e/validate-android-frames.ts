/**
 * Validates the frames the Android app produces against the protocol's own schemas.
 *
 * The phone is the third implementation of this protocol, and the one hardest to inspect while it
 * runs. Reading its real output through the same validator the host uses keeps it honest.
 */
import { readFileSync } from 'node:fs';
import { validateDataChannelMessage } from '../../packages/protocol/src/validate.ts';

const path = process.argv[2] ?? 'apps/android/app/build/frames.json';
const frames = JSON.parse(readFileSync(path, 'utf8')) as unknown[];
if (frames.length === 0) throw new Error('no frames to check');

let bad = 0;
for (const frame of frames) {
  const result = validateDataChannelMessage(frame);
  const type = (frame as { type?: string }).type ?? '?';
  if (result.valid) {
    console.log(`ok    ${type}`);
  } else {
    bad += 1;
    console.log(`FAIL  ${type}: ${result.errors.join('; ')}`);
  }
}
console.log(`\n${frames.length - bad} of ${frames.length} frames valid`);
process.exit(bad === 0 ? 0 : 1);
