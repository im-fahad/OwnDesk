import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { turnCredentials } from '../src/index.ts';
import { loadVector } from './helpers.ts';

type TurnVector = { secret: string; device_id: string; now_ms: number; ttl_s: number; username: string; credential: string; expires_at: number };
const vec = loadVector<TurnVector>('turn.json');

test('TURN credentials match vector and coturn algorithm', async () => {
  const c = await turnCredentials(vec.secret, vec.device_id, vec.now_ms, vec.ttl_s);
  assert.deepEqual(c, { username: vec.username, credential: vec.credential, expires_at: vec.expires_at });
  assert.equal(c.username, `${Math.floor(vec.now_ms / 1000) + vec.ttl_s}:${vec.device_id}`);
  assert.equal(createHmac('sha1', vec.secret).update(vec.username).digest('base64'), vec.credential);
});
