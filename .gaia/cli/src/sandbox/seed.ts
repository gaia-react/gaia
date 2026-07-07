/**
 * Injectable sandbox seed-config builder (UAT-008).
 *
 * Pure: `extractRegistryHost` parses a package-registry URL down to its
 * host only (never credentials); `seedSandboxConfig` builds the minimal
 * `sandbox` settings fragment `gaia sandbox apply` (./apply.ts, ./index.ts)
 * deep-merges into `.claude/settings.local.json`.
 */
const DEFAULT_REGISTRY_HOST = 'registry.npmjs.org';

export const extractRegistryHost = (
  registryValue: string | undefined
): string => {
  if (registryValue === undefined || registryValue.trim() === '') {
    return DEFAULT_REGISTRY_HOST;
  }

  try {
    // `URL#host` is hostname (+ port when non-default); it never includes
    // userinfo (SEC-005) or the path, satisfying the credential-free
    // contract regardless of what the caller passes in.
    return new URL(registryValue).host;
  } catch {
    return DEFAULT_REGISTRY_HOST;
  }
};

export type SandboxSettingsFragment = {
  sandbox: {
    enabled: true;
    excludedCommands?: string[];
    network: {allowedDomains: string[]};
  };
};

export type SeedInput = {
  dockerPresent: boolean;
  registry: string | undefined;
};

export const seedSandboxConfig = (
  input: SeedInput
): SandboxSettingsFragment => {
  const {dockerPresent, registry} = input;
  const allowedDomains = [extractRegistryHost(registry)];

  if (dockerPresent) {
    return {
      sandbox: {
        enabled: true,
        excludedCommands: ['docker *'],
        network: {allowedDomains},
      },
    };
  }

  return {
    sandbox: {
      enabled: true,
      network: {allowedDomains},
    },
  };
};
