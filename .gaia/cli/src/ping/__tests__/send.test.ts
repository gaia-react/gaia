import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the shared `postPing` core.
 */
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {postPing} from '../send.js';

const UUID_V4_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

describe('postPing', () => {
  let root: string;
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-ping-send-'));
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    fetchSpy = vi.fn().mockResolvedValue(new Response(null, {status: 204}));
    vi.stubGlobal('fetch', fetchSpy);
    vi.stubEnv('GAIA_TELEMETRY_PING_DISABLE', '');
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  test('posts event, gaiaVersion (from manifest), platform, and projectId', async () => {
    writeFileSync(
      path.join(root, '.gaia', 'manifest.json'),
      JSON.stringify({version: '1.6.1'}),
      'utf8'
    );

    await postPing(root, {event: 'init'});

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://telemetry.gaiareact.com/ping');
    expect(init.method).toBe('POST');
    expect((init.headers as Record<string, string>)['content-type']).toBe(
      'application/json'
    );
    const body = JSON.parse(init.body as string) as Record<string, unknown>;
    expect(body.event).toBe('init');
    expect(body.gaiaVersion).toBe('1.6.1');
    expect(body.platform).toBe(process.platform);
    expect(body.projectId).toMatch(UUID_V4_RE);
  });

  test('preserves event-specific payload keys alongside the injected fields', async () => {
    await postPing(root, {
      ci: 'custom',
      event: 'init',
      i18n: 2,
      mode: 'interactive',
    });

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(init.body as string) as Record<string, unknown>;
    expect(body).toMatchObject({
      ci: 'custom',
      event: 'init',
      i18n: 2,
      mode: 'interactive',
    });
  });

  test('injects a UUIDv4 projectId and creates .gaia/local/.project-id', async () => {
    const projectIdPath = path.join(root, '.gaia', 'local', '.project-id');
    expect(existsSync(projectIdPath)).toBe(false);

    await postPing(root, {event: 'update'});

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(init.body as string) as Record<string, unknown>;
    expect(body.projectId).toMatch(UUID_V4_RE);
    expect(existsSync(projectIdPath)).toBe(true);
  });

  test('best-effort projectId: omits it (never throws) when project-id creation fails', async () => {
    // Replace .gaia with a regular file so mkdirSync('<root>/.gaia/local')
    // inside readOrCreateProjectId throws (parent segment is not a directory).
    rmSync(path.join(root, '.gaia'), {force: true, recursive: true});
    writeFileSync(path.join(root, '.gaia'), 'not a directory', 'utf8');

    await expect(postPing(root, {event: 'setup'})).resolves.toBeUndefined();

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(init.body as string) as Record<string, unknown>;
    expect(body.projectId).toBeUndefined();
    expect(body.gaiaVersion).toBe('unknown');
  });

  test('falls back to "unknown" when the manifest is missing', async () => {
    await postPing(root, {event: 'init'});

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(init.body as string).gaiaVersion).toBe('unknown');
  });

  test('falls back to "unknown" when the manifest is malformed', async () => {
    writeFileSync(
      path.join(root, '.gaia', 'manifest.json'),
      '{ broken',
      'utf8'
    );

    await postPing(root, {event: 'init'});

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(init.body as string).gaiaVersion).toBe('unknown');
  });

  test('swallows a rejected fetch without throwing', async () => {
    fetchSpy.mockRejectedValue(new Error('network down'));

    await expect(postPing(root, {event: 'init'})).resolves.toBeUndefined();
  });

  test('no-ops (no fetch) when GAIA_TELEMETRY_PING_DISABLE=1', async () => {
    vi.stubEnv('GAIA_TELEMETRY_PING_DISABLE', '1');

    await postPing(root, {event: 'init'});

    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
