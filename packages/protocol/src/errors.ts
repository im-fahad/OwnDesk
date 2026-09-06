/** Error thrown by the protocol reference implementation. `code` is stable and machine-readable. */
export class ProtocolError extends Error {
  readonly code: string;
  constructor(code: string, detail?: string) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = 'ProtocolError';
    this.code = code;
  }
}
