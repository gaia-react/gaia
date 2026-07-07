/**
 * Tests for `classifyCapability` (UAT-003/004/005).
 */
import {describe, expect, test} from 'vitest';
import {classifyCapability} from '../capability.js';

describe('classifyCapability', () => {
  test('darwin is always ready', () => {
    const result = classifyCapability({platform: 'darwin'});

    expect(result.capability).toBe('ready');
    expect(result.installCommand).toBeUndefined();
  });

  test('darwin wins even if wsl is nonsensically supplied', () => {
    const result = classifyCapability({platform: 'darwin', wsl: 'wsl1'});

    expect(result.capability).toBe('ready');
  });

  test('linux with bwrap and socat is ready', () => {
    const result = classifyCapability({
      hasBwrap: true,
      hasSocat: true,
      platform: 'linux',
    });

    expect(result.capability).toBe('ready');
  });

  test('linux missing bwrap is needs-deps with the pinned apt install command and a Fedora mention', () => {
    const result = classifyCapability({
      hasBwrap: false,
      hasSocat: true,
      platform: 'linux',
    });

    expect(result.capability).toBe('needs-deps');
    expect(result.installCommand).toBe('sudo apt-get install bubblewrap socat');
    expect(result.reason).toContain('sudo dnf install bubblewrap socat');
  });

  test('linux missing socat is needs-deps with the pinned apt install command', () => {
    const result = classifyCapability({
      hasBwrap: true,
      hasSocat: false,
      platform: 'linux',
    });

    expect(result.capability).toBe('needs-deps');
    expect(result.installCommand).toBe('sudo apt-get install bubblewrap socat');
  });

  test('linux missing both deps is needs-deps', () => {
    const result = classifyCapability({platform: 'linux'});

    expect(result.capability).toBe('needs-deps');
  });

  test('wsl2 missing deps is needs-deps (linux path applies under WSL2)', () => {
    const result = classifyCapability({
      hasBwrap: false,
      hasSocat: false,
      platform: 'linux',
      wsl: 'wsl2',
    });

    expect(result.capability).toBe('needs-deps');
  });

  test('wsl2 with deps present is ready', () => {
    const result = classifyCapability({
      hasBwrap: true,
      hasSocat: true,
      platform: 'linux',
      wsl: 'wsl2',
    });

    expect(result.capability).toBe('ready');
  });

  test('win32 is unsupported and names WSL2 as the path', () => {
    const result = classifyCapability({platform: 'win32'});

    expect(result.capability).toBe('unsupported');
    expect(result.installCommand).toBeUndefined();
    expect(result.reason).toContain('WSL2');
  });

  test('win32 wins even if wsl2 is nonsensically supplied', () => {
    const result = classifyCapability({platform: 'win32', wsl: 'wsl2'});

    expect(result.capability).toBe('unsupported');
  });

  test('wsl1 is unsupported and names WSL2 as the path', () => {
    const result = classifyCapability({platform: 'linux', wsl: 'wsl1'});

    expect(result.capability).toBe('unsupported');
    expect(result.reason).toContain('WSL2');
  });
});
