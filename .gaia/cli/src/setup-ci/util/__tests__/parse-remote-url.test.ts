import {describe, expect, test} from 'vitest';
import {parseRemoteUrl} from '../parse-remote-url.js';

describe('parseRemoteUrl', () => {
  describe('accepted forms', () => {
    test('parses scp-style SSH with .git', () => {
      expect(parseRemoteUrl('git@github.com:owner/repo.git')).toEqual({
        host: 'github.com',
        owner: 'owner',
        repo: 'repo',
        url: 'git@github.com:owner/repo.git',
      });
    });

    test('parses scp-style SSH without .git', () => {
      expect(parseRemoteUrl('git@github.com:owner/repo')).toEqual({
        host: 'github.com',
        owner: 'owner',
        repo: 'repo',
        url: 'git@github.com:owner/repo',
      });
    });

    test('parses HTTPS with .git', () => {
      expect(parseRemoteUrl('https://github.com/owner/repo.git')).toEqual({
        host: 'github.com',
        owner: 'owner',
        repo: 'repo',
        url: 'https://github.com/owner/repo.git',
      });
    });

    test('parses HTTPS without .git', () => {
      expect(parseRemoteUrl('https://github.com/owner/repo')).toEqual({
        host: 'github.com',
        owner: 'owner',
        repo: 'repo',
        url: 'https://github.com/owner/repo',
      });
    });

    test('parses ssh:// protocol with .git', () => {
      expect(parseRemoteUrl('ssh://git@github.com/owner/repo.git')).toEqual({
        host: 'github.com',
        owner: 'owner',
        repo: 'repo',
        url: 'ssh://git@github.com/owner/repo.git',
      });
    });

    test('preserves non-github host (caller branches on host)', () => {
      const result = parseRemoteUrl('https://gitlab.com/owner/repo.git');
      expect(result?.host).toBe('gitlab.com');
      expect(result?.owner).toBe('owner');
      expect(result?.repo).toBe('repo');
    });

    test('preserves non-github host on scp-style', () => {
      const result = parseRemoteUrl('git@bitbucket.org:owner/repo.git');
      expect(result?.host).toBe('bitbucket.org');
    });
  });

  describe('rejection cases', () => {
    test('returns null for empty string', () => {
      expect(parseRemoteUrl('')).toBeNull();
    });

    test('returns null for whitespace', () => {
      expect(parseRemoteUrl(' '.repeat(3))).toBeNull();
    });

    test('returns null for malformed URL', () => {
      expect(parseRemoteUrl('not a url')).toBeNull();
    });

    test('returns null for HTTPS with subgroups (3 path segments)', () => {
      expect(parseRemoteUrl('https://gitlab.com/foo/bar/baz.git')).toBeNull();
    });

    test('returns null for SSH with subgroups', () => {
      expect(
        parseRemoteUrl('git@gitlab.com:group/subgroup/repo.git')
      ).toBeNull();
    });

    test('returns null for missing repo', () => {
      expect(parseRemoteUrl('https://github.com/owner')).toBeNull();
    });

    test('returns null for trailing-slash-only URL', () => {
      expect(parseRemoteUrl('https://github.com/')).toBeNull();
    });

    test('returns null for ssh:// missing path', () => {
      expect(parseRemoteUrl('ssh://git@github.com/')).toBeNull();
    });
  });
});
