/**
 * Injectable machine sandbox-capability classifier (UAT-003/004/005).
 *
 * Pure: takes a fully-supplied `DetectionInput` and returns a
 * `DetectionResult` with no host I/O. `gaia sandbox detect` (./index.ts)
 * falls back to real host probes (process.platform, `command -v
 * bwrap`/`socat`, WSL detection) for whichever flags are omitted, then
 * calls this function, so the tier/seed/apply UATs run deterministically
 * on `ubuntu-latest` CI regardless of the runner's real OS (AUDIT
 * plan-time directive #4).
 */
export type Capability = 'needs-deps' | 'ready' | 'unsupported';

export type DetectionInput = {
  hasBwrap?: boolean;
  hasSocat?: boolean;
  platform: Platform;
  wsl?: WslKind;
};

export type DetectionResult = {
  capability: Capability;
  installCommand?: string;
  reason: string;
};

export type Platform = 'darwin' | 'linux' | 'win32';

export type WslKind = 'none' | 'wsl1' | 'wsl2';

export const APT_INSTALL_COMMAND = 'sudo apt-get install bubblewrap socat';
const DNF_INSTALL_COMMAND = 'sudo dnf install bubblewrap socat';

export const classifyCapability = (input: DetectionInput): DetectionResult => {
  const {hasBwrap = false, hasSocat = false, platform, wsl = 'none'} = input;

  // Checked first so a nonsensical `wsl` value supplied alongside 'darwin'
  // never overrides the macOS result; `wsl` is only meaningful on linux.
  if (platform === 'darwin') {
    return {
      capability: 'ready',
      reason: 'macOS Seatbelt is built in; nothing to install.',
    };
  }

  if (platform === 'win32' || wsl === 'wsl1') {
    return {
      capability: 'unsupported',
      reason:
        'Native Windows and WSL1 have no bubblewrap/socat sandbox support; use WSL2 instead.',
    };
  }

  if (hasBwrap && hasSocat) {
    return {
      capability: 'ready',
      reason: 'bubblewrap and socat are both installed.',
    };
  }

  return {
    capability: 'needs-deps',
    installCommand: APT_INSTALL_COMMAND,
    reason: `Missing bubblewrap and/or socat. Debian/Ubuntu: ${APT_INSTALL_COMMAND}. Fedora: ${DNF_INSTALL_COMMAND}.`,
  };
};
