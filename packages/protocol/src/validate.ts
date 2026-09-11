/** JSON Schema validation for every wire message. Schemas live in ../schemas and are the source of truth. */
import { readdirSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import type { ErrorObject } from 'ajv';
import { ProtocolError } from './errors.ts';
import { SIGNALING_TYPES, isSignalingType } from './envelope.ts';

export const SCHEMA_BASE = 'https://prc.local/schemas';
export const SCHEMA_DIR = join(import.meta.dirname, '..', 'schemas');

export const DATACHANNEL_TYPES = [
  'mouse_move',
  'mouse_move_rel',
  'mouse_down',
  'mouse_up',
  'scroll',
  'key_down',
  'key_up',
  'text',
  'hello',
  'display_info',
  'capture_state',
  'stream_settings',
  'ping',
  'pong',
  'bye',
] as const;
export type DataChannelType = (typeof DATACHANNEL_TYPES)[number];

export const SERVER_FRAME_KINDS = ['auth_challenge', 'auth', 'auth_ok', 'trust_sync', 'presence', 'relay', 'error', 'ping', 'pong'] as const;
export type ServerFrameKind = (typeof SERVER_FRAME_KINDS)[number];

export function isDataChannelType(t: string): t is DataChannelType {
  return (DATACHANNEL_TYPES as readonly string[]).includes(t);
}
export function isServerFrameKind(k: string): k is ServerFrameKind {
  return (SERVER_FRAME_KINDS as readonly string[]).includes(k);
}

function loadSchema(rel: string): object {
  return JSON.parse(readFileSync(join(SCHEMA_DIR, rel), 'utf8')) as object;
}

// ajv ships CommonJS. Under Node ESM resolution its default import is the module namespace,
// so load it through require, which hands back the class itself.
const require = createRequire(import.meta.url);
const Ajv2020 = require('ajv/dist/2020.js') as typeof import('ajv/dist/2020.js').default;
const addFormats = require('ajv-formats') as typeof import('ajv-formats').default;

const ajv = new Ajv2020({ allErrors: false, strict: true, allowUnionTypes: true });
addFormats(ajv);
for (const f of ['common.json', 'envelope.json', 'qr-payload.json']) ajv.addSchema(loadSchema(f));
for (const dir of ['signaling', 'datachannel', 'server']) {
  for (const f of readdirSync(join(SCHEMA_DIR, dir))) ajv.addSchema(loadSchema(`${dir}/${f}`));
}

// Fail fast at load time if a schema set and a type list drift apart.
for (const t of SIGNALING_TYPES) if (!ajv.getSchema(`${SCHEMA_BASE}/signaling/${t}.json`)) throw new Error(`missing schema for ${t}`);
for (const t of DATACHANNEL_TYPES) if (!ajv.getSchema(`${SCHEMA_BASE}/datachannel/${t}.json`)) throw new Error(`missing schema for ${t}`);
for (const k of SERVER_FRAME_KINDS) if (!ajv.getSchema(`${SCHEMA_BASE}/server/${k}.json`)) throw new Error(`missing schema for ${k}`);

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

function run(id: string, value: unknown): ValidationResult {
  const fn = ajv.getSchema(id);
  if (!fn) throw new ProtocolError('unknown_schema', id);
  if (fn(value)) return { valid: true, errors: [] };
  return { valid: false, errors: (fn.errors ?? []).map((e: ErrorObject) => `${e.instancePath || '/'} ${e.message ?? ''}`.trim()) };
}

export function validateEnvelopeShape(value: unknown): ValidationResult {
  return run(`${SCHEMA_BASE}/envelope.json`, value);
}

export function validateSignalingPayload(type: string, value: unknown): ValidationResult {
  if (!isSignalingType(type)) return { valid: false, errors: [`unknown signaling type ${type}`] };
  return run(`${SCHEMA_BASE}/signaling/${type}.json`, value);
}

export function validateDataChannelMessage(value: unknown): ValidationResult {
  const t = typeof value === 'object' && value !== null ? (value as { type?: unknown }).type : undefined;
  if (typeof t !== 'string' || !isDataChannelType(t)) return { valid: false, errors: ['unknown data channel type'] };
  return run(`${SCHEMA_BASE}/datachannel/${t}.json`, value);
}

export function validateServerFrame(value: unknown): ValidationResult {
  const k = typeof value === 'object' && value !== null ? (value as { kind?: unknown }).kind : undefined;
  if (typeof k !== 'string' || !isServerFrameKind(k)) return { valid: false, errors: ['unknown server frame kind'] };
  return run(`${SCHEMA_BASE}/server/${k}.json`, value);
}

export function validateQrPayload(value: unknown): ValidationResult {
  return run(`${SCHEMA_BASE}/qr-payload.json`, value);
}
