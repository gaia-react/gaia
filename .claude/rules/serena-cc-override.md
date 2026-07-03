# Serena Claude-Code Override

Serena exposes LSP-backed, symbol-aware tools that return canonical, type-resolved answers where the built-in Read and Grep return string matches. When Serena is available, prefer its symbol tools for symbol-level TS/TSX work. Opus otherwise defaults to its own built-in tools even when a symbol tool fits better, so name the right tool deliberately.

## When Serena is available, prefer

- `find_symbol` over grep/Read to locate where a symbol is defined or to read its body.
- `find_referencing_symbols` over grep to find callers or references.
- `get_symbols_overview` over reading a whole file to see its structure.
- `rename_symbol` over find-and-replace to rename a symbol across the repo.

Reach for the symbol tool first on a code file. Fall back to Read/Grep only when the target is not parseable as code, when you need a cross-file regex the symbol tools cannot express, or when a few lines are all you need. Read and Grep stay right for prose, comments, string literals, and non-code files (markdown, JSON, YAML, config).

This is guidance, not a hard rule: when Serena is not registered, it is inert.
