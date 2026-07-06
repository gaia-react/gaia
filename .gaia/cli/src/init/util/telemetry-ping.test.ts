/**
 * Tests for the anonymous init ping.
 */
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {sendTelemetryPing} from './telemetry-ping.js';

describe('sendTelemetryPing', () => {
  let root: string;
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-telemetry-ping-'));
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    fetchSpy = vi.fn().mockResolvedValue(new Response(null, {status: 204}));
    vi.stubGlobal('fetch', fetchSpy);
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  test('posts event, gaiaVersion (from manifest), and platform', async () => {
    writeFileSync(
      path.join(root, '.gaia', 'manifest.json'),
      JSON.stringify({version: '1.6.1'}),
      'utf8'
    );

    await sendTelemetryPing(root);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://telemetry.gaiareact.com/ping');
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body as string)).toEqual({
      event: 'init',
      gaiaVersion: '1.6.1',
      platform: process.platform,
    });
  });

  test('falls back to "unknown" when the manifest is missing', async () => {
    await sendTelemetryPing(root);

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(init.body as string).gaiaVersion).toBe('unknown');
  });

  test('falls back to "unknown" when the manifest is malformed', async () => {
    writeFileSync(path.join(root, '.gaia', 'manifest.json'), '{ broken', 'utf8');

    await sendTelemetryPing(root);

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(init.body as string).gaiaVersion).toBe('unknown');
  });

  test('swallows a rejected fetch without throwing', async () => {
    fetchSpy.mockRejectedValue(new Error('network down'));

    await expect(sendTelemetryPing(root)).resolves.toBeUndefined();
  });

  test('does not call fetch when GAIA_TELEMETRY_PING_DISABLE=1', async () => {
    vi.stubEnv('GAIA_TELEMETRY_PING_DISABLE', '1');

    await sendTelemetryPing(root);

    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
