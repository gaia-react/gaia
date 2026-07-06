import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {z} from 'zod';
import {readFileSync} from 'node:fs';
import {automationConfigPath} from '../../../automation/paths.js';
import {readAutomationConfig} from '../../../schemas/automation-config.js';
import {
  assertStatusOk,
  setupSandbox,
  VALID_BASE_CONFIG,
} from '../../__tests__/sandbox.js';
import type {Sandbox} from '../../__tests__/sandbox.js';
import {writeAutomationConfig} from '../automation-write.js';

describe('writeAutomationConfig', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-config-write-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('writes the committed file with 2-space indentation and trailing newline', () => {
    writeAutomationConfig(sandbox.root, VALID_BASE_CONFIG);

    const filePath = automationConfigPath(sandbox.root);
    const raw = readFileSync(filePath, 'utf8');

    expect(raw).toContain('  "version": 1');
    expect(raw.endsWith('\n')).toBe(true);
  });

  test('round-trips through readAutomationConfig', () => {
    writeAutomationConfig(sandbox.root, {
      ...VALID_BASE_CONFIG,
      setup_complete: true,
    });

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);

    expect(result.config.setup_complete).toBe(true);
  });

  test('throws on schema-invalid payloads', () => {
    expect(() =>
      writeAutomationConfig(sandbox.root, {
        ...VALID_BASE_CONFIG,
        version: 99 as unknown as 1,
      })
    ).toThrow(z.ZodError);
  });
});
