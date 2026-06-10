# automation fixtures

Example `.gaia/automation.json` config shapes for the GAIA CI configuration.
These fixtures are not consumed in tests. They exist as **living examples**:
adopters wiring up GAIA CI read them to see what valid config shapes look like
end-to-end.

## Files

| File                                | Shape it demonstrates                                |
| ----------------------------------- | ---------------------------------------------------- |
| `automation-config-wiki-ci.json`    | Wiki under CI control, daily schedule.               |
| `automation-config-wiki-local.json` | Wiki under local control. Local hooks fire normally. |

## Validation

Each fixture round-trips through the config schema:

```ts
import {parseAutomationConfig} from '../../src/schemas/automation-config.js';
import fixture from '../../test-fixtures/automation/automation-config-wiki-ci.json';
parseAutomationConfig(fixture);
```
