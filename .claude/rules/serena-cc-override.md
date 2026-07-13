# Serena Claude-Code Override

Serena's symbol tools return canonical, type-resolved answers where the built-in Read and Grep return string matches. Opus defaults to its own built-in tools even when a symbol tool fits better, so when Serena is available, deliberately prefer its symbol tools for symbol-level code work.

`.claude/rules/code-search.md` is the single source for the routing: which symbol tool for which query, and when Grep is still right. It activates only on code files, while this rule loads at session start, so this stays as the always-on nudge and points there rather than restating the table.

Guidance, not a hard rule: when Serena is not registered, it is inert.
