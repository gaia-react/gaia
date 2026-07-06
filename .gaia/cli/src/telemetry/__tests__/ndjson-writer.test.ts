/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {appendIdempotent} from '../ndjson-writer.js';

describe('appendIdempotent', () => {
  let directory: string;

  beforeEach(() => {
    directory = mkdtempSync(path.join(tmpdir(), 'gaia-ndjson-'));
  });

  afterEach(() => {
    rmSync(directory, {force: true, recursive: true});
  });

  test('writes the line and returns {written: true} on first call', async () => {
    const filePath = path.join(directory, 'events-2026-05-07.jsonl');
    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    const line = JSON.stringify({event_id: eventId, payload: {x: 1}});

    const result = await appendIdempotent({
      eventId,
      fileMode: 0o644,
      filePath,
      line,
    });

    expect(result).toEqual({written: true});
    expect(readFileSync(filePath, 'utf8')).toBe(`${line}\n`);
    expect(statSync(filePath).mode & 0o777).toBe(0o644);
  });

  test('returns {written: false} when the same event_id is already present', async () => {
    const filePath = path.join(directory, 'events.jsonl');
    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    const line = JSON.stringify({event_id: eventId, payload: {x: 1}});

    const first = await appendIdempotent({
      eventId,
      fileMode: 0o600,
      filePath,
      line,
    });
    const second = await appendIdempotent({
      eventId,
      fileMode: 0o600,
      filePath,
      line,
    });

    expect(first).toEqual({written: true});
    expect(second).toEqual({written: false});
    // Exactly one line.
    expect(
      readFileSync(filePath, 'utf8').split('\n').filter(Boolean)
    ).toHaveLength(1);
  });

  test('appends a distinct event_id without dedup', async () => {
    const filePath = path.join(directory, 'events.jsonl');
    const a = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    const b = '01HZX0K3Q9JSAWC0TR6WYJ5ZNV';

    await appendIdempotent({
      eventId: a,
      fileMode: 0o600,
      filePath,
      line: JSON.stringify({event_id: a}),
    });
    const result = await appendIdempotent({
      eventId: b,
      fileMode: 0o600,
      filePath,
      line: JSON.stringify({event_id: b}),
    });

    expect(result).toEqual({written: true});
    expect(
      readFileSync(filePath, 'utf8').split('\n').filter(Boolean)
    ).toHaveLength(2);
  });

  test('respects mode 600 on creation', async () => {
    const filePath = path.join(directory, 'mentorship.jsonl');
    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';

    await appendIdempotent({
      eventId,
      fileMode: 0o600,
      filePath,
      line: JSON.stringify({event_id: eventId}),
    });

    expect(existsSync(filePath)).toBe(true);
    expect(statSync(filePath).mode & 0o777).toBe(0o600);
  });

  test('tightens mode on a pre-existing looser file', async () => {
    const filePath = path.join(directory, 'pre-existing.jsonl');
    writeFileSync(filePath, '', {mode: 0o666});

    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    await appendIdempotent({
      eventId,
      fileMode: 0o600,
      filePath,
      line: JSON.stringify({event_id: eventId}),
    });

    expect(statSync(filePath).mode & 0o777).toBe(0o600);
  });

  test('dedupes an event_id already present on disk from a prior process', async () => {
    // The in-memory seen-set is empty at process start, so a duplicate
    // that only exists on disk must still be caught by a content check.
    const filePath = path.join(directory, 'prior-run.jsonl');
    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    const line = JSON.stringify({event_id: eventId, payload: {x: 1}});
    writeFileSync(filePath, `${line}\n`, {mode: 0o600});

    const result = await appendIdempotent({
      eventId,
      fileMode: 0o600,
      filePath,
      line,
    });

    expect(result).toEqual({written: false});
    expect(
      readFileSync(filePath, 'utf8').split('\n').filter(Boolean)
    ).toHaveLength(1);
  });

  test('dedupes a repeated event_id across many appends without growth', async () => {
    const filePath = path.join(directory, 'repeated.jsonl');
    const eventId = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
    const line = JSON.stringify({event_id: eventId});

    for (let index = 0; index < 25; index += 1) {
      await appendIdempotent({eventId, fileMode: 0o600, filePath, line});
    }

    expect(
      readFileSync(filePath, 'utf8').split('\n').filter(Boolean)
    ).toHaveLength(1);
  });
});
