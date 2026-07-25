/**
 * Main-checkout fixture for tests: a real, disposable git repository with
 * one commit, standing in for an adopter's main checkout.
 *
 * The temp root is `realpathSync`'d because `os.tmpdir()` is a symlinked
 * path on macOS (`/var/folders/…` -> `/private/var/folders/…`) and git
 * canonicalizes the path it records for a linked worktree while returning a
 * caller-relative `.git` from the main checkout. Canonicalizing here is the
 * concurrency harness's own convention (`gaia_mk_tmp` uses `pwd -P`) and
 * keeps callers measuring main-anchoring rather than path form;
 * `resolveMainWorktreeRoot` itself deliberately does NOT physically resolve
 * the path it returns (see its docblock), because that string is hashed
 * into an adopter's project id and canonicalizing it would rotate every
 * existing adopter's identity.
 */
import {execFileSync} from 'node:child_process';
import {mkdtempSync, realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const git = (cwd: string, args: string[]): void => {
  execFileSync('git', args, {cwd, stdio: ['ignore', 'ignore', 'pipe']});
};

/** @param prefix - `mkdtemp` prefix; distinguishes callers' temp dirs. */
export const newMainCheckout = (prefix = 'gaia-main-checkout-'): string => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), prefix)));
  git(root, ['init', '-q', '--initial-branch=main']);
  git(root, ['config', 'user.email', 'test@example.com']);
  git(root, ['config', 'user.name', 'Test']);
  git(root, ['config', 'commit.gpgsign', 'false']);
  git(root, ['commit', '-q', '--allow-empty', '-m', 'init']);

  return root;
};
