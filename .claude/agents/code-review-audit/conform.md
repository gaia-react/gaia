---
subagents: [react-patterns, typescript]
library: '@conform-to/zod'
---

# Conform + Zod Audit Rules

- `@conform-to/zod` must **always** be imported from the `/v4` subpath. Flag any import from the bare `@conform-to/zod` package as **Critical**. The default export targets Zod v3 and causes a silent runtime failure, typecheck, lint, and build do not catch it.

```tsx
// BAD, runtime failure, no build-time error
import {parseWithZod} from '@conform-to/zod';
import {getZodConstraint} from '@conform-to/zod';

// GOOD
import {parseWithZod} from '@conform-to/zod/v4';
import {getZodConstraint} from '@conform-to/zod/v4';
```
