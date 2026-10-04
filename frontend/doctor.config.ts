// React Doctor configuration.
//
// react-doctor runs via `npx react-doctor@latest` (it is not a project
// dependency), so this is a plain `export default` rather than importing
// react-doctor's config type. The `.ts` extension matches the repo's config
// convention (vite/knip/playwright/react-router) and is the highest-precedence
// extension react-doctor resolves, so a stray doctor.config.json/.jsonc can
// never silently shadow it. A pre-commit hook fails if more than one
// react-doctor config file exists.

export default {
  // Dead-code analysis (deslop: unused files/exports/deps) is owned by knip,
  // which runs in CI alongside react-doctor and carries a curated
  // `ignoreDependencies` list plus app/services|hooks|utils + test as entry
  // points (see knip.config.ts). react-doctor's deslop pass re-flags that same
  // intentional template surface: scaffolding entry points the new-service
  // skill extends, documented public helpers, and template-only deps. Disable
  // the duplicate pass; knip remains the single dead-code authority.
  deadCode: false,

  ignore: {
    // Generated build output is not source; never scan it. Drops the
    // artifact-env-leak finding on build/server/index.js.map.
    files: ['build/**'],

    // Per-path rule suppressions. Each rule stays active everywhere else;
    // these are evidenced false positives at specific sites, not blanket-offs.
    overrides: [
      {
        // Route modules must co-locate loader/middleware/meta exports with the
        // default component export; framework-mandated by React Router, not a
        // Fast-Refresh hazard. Rule stays active for non-route component files.
        files: ['app/root.tsx', 'app/routes/**'],
        rules: ['react-doctor/only-export-components'],
      },
      {
        // Both dangerouslySetInnerHTML sites inject trusted, nonce'd content:
        // Document injects a compile-time-constant theme script; root injects
        // JSON.stringify(envClient) (server-controlled build config), HTML-escaped
        // against script-tag breakout. No user input reaches either. Rule stays
        // active everywhere else so any new dangerouslySetInnerHTML is flagged.
        files: ['app/components/document/index.tsx', 'app/root.tsx'],
        rules: ['react-doctor/no-danger'],
      },
      {
        // role="group" is the correct ARIA for these control groupings; the
        // rule's suggested <address> replacement is semantically wrong (no HTML
        // tag maps to role="group" without <fieldset> legend/style baggage).
        // These are reusable grouping primitives that may nest inside a
        // consumer's own <fieldset>, so role="group" on a <div> stays correct.
        files: [
          'app/components/form/chain/index.tsx',
          'app/components/form/checkbox-radio-group/index.tsx',
        ],
        rules: ['react-doctor/prefer-tag-over-role'],
      },
      {
        // Storybook stories are dev-only demos, never shipped or a11y-audited
        // in production; the literal "link" anchor text is intentional sample
        // content demonstrating a link inside a label.
        files: ['**/*.stories.tsx'],
        rules: ['react-doctor/anchor-ambiguous-text'],
      },
    ],
  },
};
