/**
 * Tests for `extractRegistryHost` and `seedSandboxConfig` (UAT-008).
 */
import {describe, expect, test} from 'vitest';
import {extractRegistryHost, seedSandboxConfig} from '../seed.js';

describe('extractRegistryHost', () => {
  test('undefined falls back to the default registry host', () => {
    expect(extractRegistryHost(undefined)).toBe('registry.npmjs.org');
  });

  test('empty string falls back to the default registry host', () => {
    expect(extractRegistryHost('')).toBe('registry.npmjs.org');
  });

  test('unparseable value falls back to the default registry host', () => {
    expect(extractRegistryHost('not a url')).toBe('registry.npmjs.org');
  });

  test('the default registry URL round-trips to its own host', () => {
    expect(extractRegistryHost('https://registry.npmjs.org/')).toBe(
      'registry.npmjs.org'
    );
  });

  test('a credential-bearing URL yields host only, never the credentials', () => {
    const host = extractRegistryHost('https://user:token@npm.example.com/');

    expect(host).toBe('npm.example.com');
    expect(host).not.toContain('user');
    expect(host).not.toContain('token');
  });
});

describe('seedSandboxConfig', () => {
  test('default registry: allowedDomains is exactly [registry.npmjs.org]', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: undefined,
    });

    expect(fragment.sandbox.network.allowedDomains).toEqual([
      'registry.npmjs.org',
    ]);
  });

  test('dockerPresent true: excludedCommands contains "docker *"', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: true,
      registry: undefined,
    });

    expect(fragment.sandbox.excludedCommands).toContain('docker *');
  });

  test('dockerPresent false: the excludedCommands key is absent', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: undefined,
    });

    expect('excludedCommands' in fragment.sandbox).toBe(false);
  });

  test('sandbox.enabled is always true', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: undefined,
    });

    expect(fragment.sandbox.enabled).toBe(true);
  });

  test('a custom registry resolves to its own host in allowedDomains', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: 'https://user:token@npm.example.com/',
    });

    expect(fragment.sandbox.network.allowedDomains).toEqual([
      'npm.example.com',
    ]);
  });
});
