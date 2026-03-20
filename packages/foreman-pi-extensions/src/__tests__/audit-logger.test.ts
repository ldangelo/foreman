/**
 * Tests for the foreman-audit extension (audit-logger.ts)
 * TDD — RED/GREEN phases covering:
 *   - Original JSONL-writing behaviour (unchanged)
 *   - Agent Mail streaming (primary store)
 *   - Buffering when Agent Mail is down
 *   - Buffer flush on Agent Mail recovery
 *   - Observer-only guarantee
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { readFileSync, existsSync, mkdirSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

import { createAuditExtension } from '../audit-logger.js';
import type { ExtensionContext } from '../types.js';

// ── fetch mock ────────────────────────────────────────────────────────────────
// We mock globalThis.fetch so tests never hit a real network.

type FetchFn = typeof fetch;

/** Build a mock fetch that resolves with a given status code. */
function makeFetchMock(status: number): FetchFn {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
  } as Response);
}

/** Build a mock fetch that rejects with a network error. */
function makeFailingFetch(): FetchFn {
  return vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));
}

// ── helpers ──────────────────────────────────────────────────────────────────

function makeTmpDir(): string {
  const dir = join(tmpdir(), `foreman-audit-test-${randomUUID()}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function readJSONL(filePath: string): Record<string, unknown>[] {
  const text = readFileSync(filePath, 'utf-8');
  return text
    .split('\n')
    .filter(line => line.trim().length > 0)
    .map(line => JSON.parse(line) as Record<string, unknown>);
}

function auditFilePath(dir: string, runId: string): string {
  return join(dir, `${runId}.jsonl`);
}

// ── shared fixtures ───────────────────────────────────────────────────────────

const RUN_ID = 'run-test';
const SEED_ID = 'seed-test';
const PHASE = 'explorer';

const mockCtx: ExtensionContext = {
  phase: PHASE,
  runId: RUN_ID,
  seedId: SEED_ID,
  getContextUsage: () => ({ totalTokens: 1000, inputTokens: 800, outputTokens: 200 }),
  log: vi.fn(),
};

beforeEach(() => {
  process.env['FOREMAN_RUN_ID'] = RUN_ID;
  process.env['FOREMAN_SEED_ID'] = SEED_ID;
  process.env['FOREMAN_PHASE'] = PHASE;
});

// ── tests ─────────────────────────────────────────────────────────────────────

describe('createAuditExtension', () => {
  it('has correct name and version', () => {
    const ext = createAuditExtension(makeTmpDir());
    expect(ext.name).toBe('foreman-audit');
    expect(ext.version).toBe('1.0.0');
  });

  // 1. onToolCall writes correct JSONL entry
  describe('onToolCall', () => {
    it('writes a JSONL line with eventType=tool_call, toolName, phase, runId, seedId, timestamp', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolCall?.(
        { toolName: 'Bash', input: { command: 'ls' } },
        mockCtx,
      );

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['eventType']).toBe('tool_call');
      expect(entry['toolName']).toBe('Bash');
      expect(entry['runId']).toBe(RUN_ID);
      expect(entry['seedId']).toBe(SEED_ID);
      expect(entry['phase']).toBe(PHASE);
      expect(typeof entry['timestamp']).toBe('string');
      // ISO 8601 — must be parseable as a date
      expect(new Date(entry['timestamp'] as string).toISOString()).toBe(entry['timestamp']);
    });

    // 9. onToolCall always returns undefined (observer only)
    it('always returns undefined — never blocks', () => {
      const ext = createAuditExtension(makeTmpDir());
      const result = ext.onToolCall?.(
        { toolName: 'Read', input: { file_path: '/tmp/x' } },
        mockCtx,
      );
      expect(result).toBeUndefined();
    });
  });

  // 2. onTurnEnd writes correct JSONL entry
  describe('onTurnEnd', () => {
    it('writes a JSONL line with eventType=turn_end, turnNumber, totalTokens', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onTurnEnd?.(
        { turnNumber: 5, contextUsage: { totalTokens: 2000, inputTokens: 1600, outputTokens: 400 } },
        mockCtx,
      );

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['eventType']).toBe('turn_end');
      expect(entry['turnNumber']).toBe(5);
      expect(entry['totalTokens']).toBe(2000);
      expect(entry['runId']).toBe(RUN_ID);
      expect(entry['seedId']).toBe(SEED_ID);
      expect(entry['phase']).toBe(PHASE);
    });
  });

  // 3. onAgentEnd writes correct JSONL entry
  describe('onAgentEnd', () => {
    it('writes a JSONL line with eventType=agent_end, reason, totalTokens when provided', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onAgentEnd?.(
        {
          reason: 'completed',
          finalContextUsage: { totalTokens: 5000, inputTokens: 4000, outputTokens: 1000 },
        },
        mockCtx,
      );

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['eventType']).toBe('agent_end');
      expect(entry['reason']).toBe('completed');
      expect(entry['totalTokens']).toBe(5000);
    });

    it('writes agent_end entry with undefined totalTokens when finalContextUsage is absent', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onAgentEnd?.({ reason: 'error', error: 'timeout' }, mockCtx);

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['reason']).toBe('error');
      // totalTokens should be absent or undefined
      expect(entry['totalTokens']).toBeUndefined();
    });
  });

  // 4. onToolExecutionStart writes correct JSONL entry
  describe('onToolExecutionStart', () => {
    it('writes a JSONL line with eventType=tool_execution_start, toolName', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolExecutionStart?.(
        { toolName: 'Write', toolCallId: 'call-abc' },
        mockCtx,
      );

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['eventType']).toBe('tool_execution_start');
      expect(entry['toolName']).toBe('Write');
    });
  });

  // 5. onToolExecutionEnd writes correct JSONL entry
  describe('onToolExecutionEnd', () => {
    it('writes a JSONL line with eventType=tool_execution_end, toolName, durationMs, success', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolExecutionEnd?.(
        { toolName: 'Write', toolCallId: 'call-abc', durationMs: 123, success: true },
        mockCtx,
      );

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(1);
      const entry = entries[0];
      expect(entry['eventType']).toBe('tool_execution_end');
      expect(entry['toolName']).toBe('Write');
      expect(entry['durationMs']).toBe(123);
      const details = entry['details'] as Record<string, unknown>;
      expect(details['success']).toBe(true);
    });
  });

  // 6. All entries include required base fields
  describe('base fields on every entry', () => {
    it('every event type includes timestamp (ISO), runId, seedId, phase', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolCall?.({ toolName: 'Glob', input: {} }, mockCtx);
      ext.onTurnEnd?.({ turnNumber: 1, contextUsage: { totalTokens: 100, inputTokens: 80, outputTokens: 20 } }, mockCtx);
      ext.onAgentEnd?.({ reason: 'cancelled' }, mockCtx);
      ext.onToolExecutionStart?.({ toolName: 'Grep', toolCallId: 'c1' }, mockCtx);
      ext.onToolExecutionEnd?.({ toolName: 'Grep', toolCallId: 'c1', durationMs: 50, success: false }, mockCtx);

      const entries = readJSONL(auditFilePath(dir, RUN_ID));
      expect(entries).toHaveLength(5);

      for (const entry of entries) {
        expect(typeof entry['timestamp']).toBe('string');
        expect(new Date(entry['timestamp'] as string).toISOString()).toBe(entry['timestamp']);
        expect(entry['runId']).toBe(RUN_ID);
        expect(entry['seedId']).toBe(SEED_ID);
        expect(entry['phase']).toBe(PHASE);
      }
    });
  });

  // 7. Silent failure when file can't be written
  describe('error resilience', () => {
    it('does not throw when the audit directory is not writable', () => {
      // Create a read-only directory
      const parentDir = makeTmpDir();
      const roDir = join(parentDir, 'readonly');
      mkdirSync(roDir, { recursive: true });
      chmodSync(roDir, 0o444); // read-only

      const ext = createAuditExtension(roDir);

      // None of these should throw
      expect(() => {
        ext.onToolCall?.({ toolName: 'Bash', input: {} }, mockCtx);
        ext.onTurnEnd?.({ turnNumber: 1, contextUsage: { totalTokens: 100, inputTokens: 80, outputTokens: 20 } }, mockCtx);
        ext.onAgentEnd?.({ reason: 'completed' }, mockCtx);
      }).not.toThrow();

      // Restore permissions so tmpdir cleanup can remove it
      chmodSync(roDir, 0o755);
    });
  });

  // 8. Multiple entries are appended line-by-line (each is valid JSON)
  describe('JSONL format', () => {
    it('appends multiple entries as separate lines, each parseable as JSON', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolCall?.({ toolName: 'Read', input: {} }, mockCtx);
      ext.onToolCall?.({ toolName: 'Write', input: {} }, mockCtx);
      ext.onToolCall?.({ toolName: 'Edit', input: {} }, mockCtx);

      const raw = readFileSync(auditFilePath(dir, RUN_ID), 'utf-8');
      const lines = raw.split('\n').filter(l => l.trim().length > 0);
      expect(lines).toHaveLength(3);

      // Every line must be independently parseable
      for (const line of lines) {
        expect(() => JSON.parse(line)).not.toThrow();
      }

      const entries = lines.map(l => JSON.parse(l) as Record<string, unknown>);
      const toolNames = entries.map(e => e['toolName']);
      expect(toolNames).toEqual(['Read', 'Write', 'Edit']);
    });

    it('uses a single file keyed by FOREMAN_RUN_ID', () => {
      const dir = makeTmpDir();
      const ext = createAuditExtension(dir);

      ext.onToolCall?.({ toolName: 'Bash', input: {} }, mockCtx);
      ext.onAgentEnd?.({ reason: 'completed' }, mockCtx);

      // File named after the run ID
      const file = join(dir, `${RUN_ID}.jsonl`);
      const entries = readJSONL(file);
      expect(entries.length).toBeGreaterThanOrEqual(2);
    });
  });
});

// ── Agent Mail integration tests ──────────────────────────────────────────────

describe('createAuditExtension — Agent Mail integration', () => {
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    process.env['FOREMAN_RUN_ID'] = RUN_ID;
    process.env['FOREMAN_SEED_ID'] = SEED_ID;
    process.env['FOREMAN_PHASE'] = PHASE;
    // Use a non-default URL so tests don't accidentally hit localhost:8765
    process.env['AGENT_MAIL_URL'] = 'http://test-agent-mail:9999';
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    delete process.env['AGENT_MAIL_URL'];
  });

  // 1. Tool call event → written to both local JSONL and Agent Mail
  it('writes tool_call event to local JSONL AND posts to Agent Mail', async () => {
    const mockFetch = makeFetchMock(200);
    globalThis.fetch = mockFetch;

    const dir = makeTmpDir();
    const bufferDir = makeTmpDir();
    const ext = createAuditExtension(dir, bufferDir);

    ext.onToolCall?.({ toolName: 'Bash', input: { command: 'ls' } }, mockCtx);

    // Let fire-and-forget promises settle
    await new Promise(resolve => setTimeout(resolve, 20));

    // Local JSONL must have the entry
    const entries = readJSONL(auditFilePath(dir, RUN_ID));
    expect(entries).toHaveLength(1);
    expect(entries[0]!['eventType']).toBe('tool_call');

    // fetch should have been called for the Agent Mail send_message endpoint
    expect(mockFetch).toHaveBeenCalled();
    const [calledUrl, calledInit] = (mockFetch as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(calledUrl).toContain('send_message');
    const body = JSON.parse(calledInit.body as string) as Record<string, unknown>;
    expect(body['to']).toBe('audit-log');
    expect(body['subject']).toBe('tool_call');
    const parsedEntry = JSON.parse(body['body'] as string) as Record<string, unknown>;
    expect(parsedEntry['eventType']).toBe('tool_call');
  });

  // 2. Agent Mail down → event written to JSONL + buffered
  it('buffers entry when Agent Mail send_message fails', async () => {
    globalThis.fetch = makeFailingFetch();

    const dir = makeTmpDir();
    const bufferDir = makeTmpDir();
    const ext = createAuditExtension(dir, bufferDir);

    ext.onToolCall?.({ toolName: 'Read', input: {} }, mockCtx);

    await new Promise(resolve => setTimeout(resolve, 20));

    // Local JSONL written
    const entries = readJSONL(auditFilePath(dir, RUN_ID));
    expect(entries).toHaveLength(1);

    // Buffer file created under bufferDir/{runId}.jsonl
    const bufferFile = join(bufferDir, `${RUN_ID}.jsonl`);
    expect(existsSync(bufferFile)).toBe(true);
    const buffered = readJSONL(bufferFile);
    expect(buffered).toHaveLength(1);
    expect(buffered[0]!['eventType']).toBe('tool_call');
  });

  // 3. Agent Mail recovers → buffer flushed before next event
  it('flushes buffer to Agent Mail when service recovers', async () => {
    // First call: Agent Mail is down — buffer the entry
    globalThis.fetch = makeFailingFetch();

    const dir = makeTmpDir();
    const bufferDir = makeTmpDir();
    const ext = createAuditExtension(dir, bufferDir);

    ext.onToolCall?.({ toolName: 'Read', input: {} }, mockCtx);
    await new Promise(resolve => setTimeout(resolve, 20));

    // Verify buffer has 1 entry
    const bufferFile = join(bufferDir, `${RUN_ID}.jsonl`);
    expect(existsSync(bufferFile)).toBe(true);

    // Second call: Agent Mail recovers — first call is health check, subsequent calls succeed
    let healthChecked = false;
    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if ((url as string).includes('/health')) {
        healthChecked = true;
        return Promise.resolve({ ok: true, status: 200 } as Response);
      }
      return Promise.resolve({ ok: true, status: 200 } as Response);
    }) as FetchFn;

    ext.onToolCall?.({ toolName: 'Write', input: {} }, mockCtx);
    await new Promise(resolve => setTimeout(resolve, 50));

    // Health check should have been called
    expect(healthChecked).toBe(true);

    // Buffer file should be deleted after successful flush
    expect(existsSync(bufferFile)).toBe(false);

    // fetch should have been called at least 3 times:
    //   1. health check
    //   2. flush of buffered entry (send_message)
    //   3. new event (send_message)
    const mockFetch = globalThis.fetch as ReturnType<typeof vi.fn>;
    expect(mockFetch.mock.calls.length).toBeGreaterThanOrEqual(3);
  });

  // 4. Observer-only: Agent Mail failure never blocks tool call
  it('never throws or blocks when Agent Mail is unreachable', () => {
    globalThis.fetch = makeFailingFetch();

    const dir = makeTmpDir();
    const bufferDir = makeTmpDir();
    const ext = createAuditExtension(dir, bufferDir);

    // All hook calls must be synchronous and must not throw
    expect(() => {
      const result = ext.onToolCall?.({ toolName: 'Bash', input: {} }, mockCtx);
      // Result must be undefined (observer-only)
      expect(result).toBeUndefined();
    }).not.toThrow();

    expect(() => {
      ext.onTurnEnd?.(
        { turnNumber: 1, contextUsage: { totalTokens: 100, inputTokens: 80, outputTokens: 20 } },
        mockCtx,
      );
    }).not.toThrow();

    expect(() => {
      ext.onAgentEnd?.({ reason: 'completed' }, mockCtx);
    }).not.toThrow();
  });
});
