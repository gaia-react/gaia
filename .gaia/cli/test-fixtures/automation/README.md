# automation fixtures

Example `.gaia/automation.json` and `.gaia/automation.state-<tool>.json`
shapes for slice 1 of the GAIA CI configuration. **Slice 1 ships these
fixtures but does not consume them in tests.** They exist for two reasons:

1. **Living examples.** Adopters wiring up GAIA CI can read these files to
   see what valid shapes look like end-to-end.
2. **Slice 2 hooks.** The future workflow-generation slice exercises the
   defer / cron-decide paths against these fixtures rather than inlining
   JSON in test bodies.

## Files

| File                                 | Shape it demonstrates                                        |
| ------------------------------------ | ------------------------------------------------------------ |
| `automation-config-wiki-ci.json`     | Wiki under CI control, daily schedule.                       |
| `automation-config-wiki-local.json`  | Wiki under local control. Local hooks fire normally.         |
| `automation-state-wiki-fresh.json`   | A run from the previous day; no overage, fresh `skip_count`. |
| `automation-state-wiki-stale.json`   | A run from > 14 days ago; triggers `ceiling_14d` decision.  |
| `automation-state-wiki-overage.json` | `cost_overage = true`; triggers `cost_overage` decision.    |

## Validation

Each fixture round-trips through the Phase 1 schemas. Slice 2 tests will
parse and use them via:

```ts
import {parseAutomationConfig} from '../../src/schemas/automation-config.js';
import fixture from '../../test-fixtures/automation/automation-config-wiki-ci.json';
parseAutomationConfig(fixture);
```
