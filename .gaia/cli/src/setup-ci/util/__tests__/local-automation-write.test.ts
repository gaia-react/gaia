import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {localAutomationPath} from '../../../automation/paths.js';
import {readLocalAutomation} from '../../../schemas/local-automation.js';
import {setupSandbox, type Sandbox} from '../../__tests__/sandbox.js';
import {writeLocalAutomation} from '../local-automation-write.js';

describe('writeLocalAutomation', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-local-write-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  it('writes the gitignored file with 2-space indentation and trailing newline', () => {
    writeLocalAutomation(sandbox.root, {nudge_dismissed: true, version: 1});

    const filePath = localAutomationPath(sandbox.root);
    const raw = readFileSync(filePath, 'utf8');

    expect(raw).toContain('  "nudge_dismissed": true');
    expect(raw.endsWith('\n')).toBe(true);
  });

  it('round-trips through the read helper', () => {
    writeLocalAutomation(sandbox.root, {nudge_dismissed: true, version: 1});

    const result = readLocalAutomation(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.local.nudge_dismissed).toBe(true);
    }
  });

  it('throws on schema-invalid payloads', () => {
    expect(() =>
      writeLocalAutomation(sandbox.root, {
        nudge_dismissed: 'yes' as unknown as boolean,
        version: 1,
      })
    ).toThrow();
  });
});
