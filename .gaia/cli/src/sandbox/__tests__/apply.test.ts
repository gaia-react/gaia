/**
 * Tests for `mergeSandboxSettings` (UAT-007).
 */
import {describe, expect, test} from 'vitest';
import {mergeSandboxSettings} from '../apply.js';
import {seedSandboxConfig} from '../seed.js';

describe('mergeSandboxSettings', () => {
  test('merges the seed fragment into an empty settings object', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: true,
      registry: undefined,
    });

    const merged = mergeSandboxSettings({}, fragment);

    expect(merged.sandbox).toEqual({
      enabled: true,
      excludedCommands: ['docker *'],
      network: {allowedDomains: ['registry.npmjs.org']},
    });
  });

  test('preserves pre-existing unrelated top-level keys', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: undefined,
    });

    const merged = mergeSandboxSettings(
      {someOtherKey: {nested: true}},
      fragment
    );

    expect(merged.someOtherKey).toEqual({nested: true});
    expect(merged.sandbox).toBeDefined();
  });

  test('merges nested rather than clobbering a pre-existing sandbox block wholesale', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: undefined,
    });

    const merged = mergeSandboxSettings(
      {sandbox: {unrelatedSandboxKey: 'keep-me'}},
      fragment
    );

    expect(merged.sandbox).toMatchObject({
      enabled: true,
      network: {allowedDomains: ['registry.npmjs.org']},
      unrelatedSandboxKey: 'keep-me',
    });
  });

  test('array values (allowedDomains) are replaced wholesale, not merged element-wise', () => {
    const fragment = seedSandboxConfig({
      dockerPresent: false,
      registry: 'https://npm.example.com/',
    });

    const merged = mergeSandboxSettings(
      {
        sandbox: {
          network: {allowedDomains: ['old.example.com']},
        },
      },
      fragment
    );

    expect(
      (merged.sandbox as {network: {allowedDomains: string[]}}).network
        .allowedDomains
    ).toEqual(['npm.example.com']);
  });
});
