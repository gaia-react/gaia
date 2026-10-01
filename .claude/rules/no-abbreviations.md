---
paths:
  - '**/*.ts'
  - '**/*.tsx'
  - '**/*.js'
  - '**/*.jsx'
  - '**/*.mjs'
  - '**/*.cjs'
  - '**/*.sh'
  - '**/*.bash'
  - '**/*.zsh'
  - '**/*.bats'
  - '**/*.py'
  - '**/*.go'
  - '**/*.rs'
  - '**/*.rb'
  - '**/*.java'
  - '**/*.kt'
  - '**/*.kts'
  - '**/*.cs'
  - '**/*.php'
  - '**/*.swift'
  - '**/*.sql'
  - '**/*.tf'
  - '**/*.yml'
  - '**/*.yaml'
  - '**/Dockerfile'
  - '**/Dockerfile.*'
---

# No Abbreviations

Spell out words in full unless the abbreviation is universally known (`url`, `id`, `api`). This is one piece of the descriptive-naming standard in the `naming-conventions` skill, which follows Apple's Swift API Design Guidelines: names should be clear at the point of use without consulting documentation.

It applies wherever a name is coined, not only in application code: a GitHub Actions job, an env var name, a Dockerfile `ARG` or `ENV` name.

## Examples

```ts
// BAD
const calcBMI = (ht: number, wt: number) => { ... }
const usrPref = getUserPref();
const animDur = 300;

// GOOD
const calculateBodyMassIndex = (heightInCentimeters: number, weightInKilograms: number) => { ... }
const userDisplayPreferences = getUserDisplayPreferences();
const animationDurationInMilliseconds = 300;
```

```bash
# BAD
tmp_f=$(mktemp)
err_msg="Build failed"
max_ret=3

# GOOD
temporary_file=$(mktemp)
error_message="Build failed"
maximum_retry_count=3
```
