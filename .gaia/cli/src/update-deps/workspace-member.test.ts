import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  CLI_WORKSPACE_MEMBER,
  readCliWorkspaceMember,
} from './workspace-member.js';

let repoRoot: string;

const writeWorkspace = (content: string): void => {
  writeFileSync(path.join(repoRoot, 'pnpm-workspace.yaml'), content);
};

const writeMemberManifest = (): void => {
  mkdirSync(path.join(repoRoot, CLI_WORKSPACE_MEMBER), {recursive: true});
  writeFileSync(
    path.join(repoRoot, CLI_WORKSPACE_MEMBER, 'package.json'),
    '{}'
  );
};

beforeEach(() => {
  repoRoot = mkdtempSync(path.join(tmpdir(), 'workspace-member-'));
});

afterEach(() => {
  rmSync(repoRoot, {force: true, recursive: true});
});

describe('readCliWorkspaceMember', () => {
  test('returns the member when the workspace lists it and its manifest exists', () => {
    writeWorkspace('packages:\n  - frontend\n  - .gaia/cli\n');
    writeMemberManifest();
    expect(readCliWorkspaceMember(repoRoot)).toBe(CLI_WORKSPACE_MEMBER);
  });

  test('returns the member for a quoted list item', () => {
    writeWorkspace("packages:\n  - frontend\n  - '.gaia/cli'\n");
    writeMemberManifest();
    expect(readCliWorkspaceMember(repoRoot)).toBe(CLI_WORKSPACE_MEMBER);
  });

  test('returns null when the workspace lists the member but its manifest is missing', () => {
    writeWorkspace('packages:\n  - frontend\n  - .gaia/cli\n');
    expect(readCliWorkspaceMember(repoRoot)).toBeNull();
  });

  test.each([
    ['does not list the member', 'packages:\n  - frontend\n'],
    ['is unparseable', 'packages: [unclosed\n  - : :\n'],
    ['has a non-list packages value', 'packages: .gaia/cli\n'],
  ])('returns null when the workspace file %s', (_label, content) => {
    writeWorkspace(content);
    writeMemberManifest();
    expect(readCliWorkspaceMember(repoRoot)).toBeNull();
  });

  test('returns null when the workspace file is missing', () => {
    writeMemberManifest();
    expect(readCliWorkspaceMember(repoRoot)).toBeNull();
  });
});
