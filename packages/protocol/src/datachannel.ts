/** Data channel protocol (spec sections 12.2 and 13): channels, limits, and message parsing. */
import { utf8Decode, utf8Encode } from './encoding.ts';
import { DATACHANNEL_TYPES, isDataChannelType, validateDataChannelMessage, type DataChannelType } from './validate.ts';

export { DATACHANNEL_TYPES, isDataChannelType, type DataChannelType };

export const MAX_DATACHANNEL_BYTES = 4096;

export const CHANNEL_LABELS = {
  lossy: 'input-lossy',
  reliable: 'input-reliable',
  control: 'control',
} as const;
export type ChannelLabel = (typeof CHANNEL_LABELS)[keyof typeof CHANNEL_LABELS];

/** RTCDataChannelInit per channel. Created by the controller before the offer. */
export const CHANNEL_CONFIG: Record<ChannelLabel, { ordered: boolean; maxRetransmits?: number }> = {
  'input-lossy': { ordered: false, maxRetransmits: 0 },
  'input-reliable': { ordered: true },
  control: { ordered: true },
};

export const CHANNEL_FOR_TYPE: Record<DataChannelType, ChannelLabel> = {
  mouse_move: 'input-lossy',
  mouse_move_rel: 'input-lossy',
  mouse_down: 'input-reliable',
  mouse_up: 'input-reliable',
  scroll: 'input-reliable',
  key_down: 'input-reliable',
  key_up: 'input-reliable',
  text: 'input-reliable',
  hello: 'control',
  display_info: 'control',
  stream_settings: 'control',
  ping: 'control',
  pong: 'control',
  bye: 'control',
};

export const MODIFIERS = ['shift', 'control', 'alt', 'meta', 'capslock'] as const;
export type Modifier = (typeof MODIFIERS)[number];

export const MOUSE_BUTTONS = ['left', 'right', 'middle'] as const;
export type MouseButton = (typeof MOUSE_BUTTONS)[number];

/** Host-side limits (spec section 21) and timing constants (sections 12.2, 13.2). */
export const LIMITS = {
  mouseEventsPerSecond: 300,
  keyEventsPerSecond: 100,
  textEventsPerSecond: 50,
  malformedPerMinuteBeforeDisconnect: 100,
  mouseMoveCoalesceMs: 4,
  pingIntervalMs: 5000,
  missedPongsBeforeReconnect: 3,
  textMaxCodePoints: 256,
  maxRelativeDelta: 4096,
  maxScrollDelta: 10000,
  doubleClickMs: 500,
  doubleClickDistancePoints: 5,
} as const;

export interface DataChannelMessageBase {
  v: number;
  type: DataChannelType;
  ts: number;
}

export type DataChannelParseResult =
  | { ok: true; message: DataChannelMessageBase & Record<string, unknown>; channel: ChannelLabel }
  | { ok: false; reason: 'too_large' | 'malformed' | 'unknown_type' | 'invalid' | 'wrong_channel'; detail?: string };

/**
 * Parse and validate one data channel frame. Never throws.
 * If `receivedOn` is given, a message arriving on the wrong channel is rejected: a `key_down`
 * on the lossy channel could be dropped silently, and a `mouse_move` on the reliable channel
 * would block real input behind retransmits.
 */
export function parseDataChannelMessage(raw: string | Uint8Array, receivedOn?: ChannelLabel): DataChannelParseResult {
  const bytes = typeof raw === 'string' ? utf8Encode(raw) : raw;
  if (bytes.length > MAX_DATACHANNEL_BYTES) return { ok: false, reason: 'too_large' };
  let parsed: unknown;
  try {
    parsed = JSON.parse(utf8Decode(bytes));
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  if (typeof parsed !== 'object' || parsed === null) return { ok: false, reason: 'malformed' };
  const t = (parsed as { type?: unknown }).type;
  if (typeof t !== 'string' || !isDataChannelType(t)) return { ok: false, reason: 'unknown_type' };
  const v = validateDataChannelMessage(parsed);
  if (!v.valid) {
    const detail = v.errors[0];
    return detail === undefined ? { ok: false, reason: 'invalid' } : { ok: false, reason: 'invalid', detail };
  }
  const channel = CHANNEL_FOR_TYPE[t];
  if (receivedOn !== undefined && receivedOn !== channel) return { ok: false, reason: 'wrong_channel', detail: `${t} belongs on ${channel}` };
  return { ok: true, message: parsed as DataChannelMessageBase & Record<string, unknown>, channel };
}
