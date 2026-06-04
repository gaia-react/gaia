---
name: playwright-cli
description: Automates browser interactions for web testing, form filling, screenshots, and data extraction. Use when the user needs to navigate websites, interact with web pages, fill forms, take screenshots, test web applications, or extract information from web pages.
allowed-tools: Bash(playwright-cli:*)
---

# Browser Automation with playwright-cli

## Quick start

```bash
# open new browser
playwright-cli open
# navigate to a page
playwright-cli goto https://playwright.dev
# interact with the page using refs from the snapshot
playwright-cli click e15
playwright-cli type "page.click"
playwright-cli press Enter
# take a screenshot (rarely used, as snapshot is more common)
playwright-cli screenshot
# close the browser
playwright-cli close
```

## How interaction refs work

After every command, playwright-cli emits a snapshot file (`.playwright-cli/page-*.yml`). Element refs (`e3`, `e7`, `e15`) come from that snapshot, read it before the next interactive command. Use `playwright-cli snapshot` to refresh on demand.

```bash
> playwright-cli goto https://example.com
### Page
- Page URL: https://example.com/
- Page Title: Example Domain
### Snapshot
[Snapshot](.playwright-cli/page-2026-02-14T19-22-42-679Z.yml)
```

If `--filename` is not provided, a new snapshot file is created with a timestamp. Default to automatic file naming; use `--filename=` when the artifact is part of the workflow result.

## Local installation fallback

If running globally-available `playwright-cli` fails, prefix with `npx`:

```bash
npx playwright-cli open https://example.com
npx playwright-cli click e1
```

## Browser sessions

Use `-s=<name>` to run multiple parallel sessions:

```bash
playwright-cli -s=mysession open example.com --persistent
playwright-cli -s=mysession click e6
playwright-cli -s=mysession close
playwright-cli list           # list active sessions
playwright-cli close-all      # close every browser
```

## Command reference

Full surface, core, navigation, keyboard, mouse, save-as, tabs, storage (cookies / localStorage / sessionStorage), network, devtools, open parameters, snapshots, browser sessions, end-to-end examples, is in [references/commands.md](references/commands.md).

## Specific tasks

- **Request mocking**: [references/request-mocking.md](references/request-mocking.md)
- **Running Playwright code**: [references/running-code.md](references/running-code.md)
- **Browser session management**: [references/session-management.md](references/session-management.md)
- **Storage state (cookies, localStorage)**: [references/storage-state.md](references/storage-state.md)
- **Test generation**: [references/test-generation.md](references/test-generation.md)
- **Tracing**: [references/tracing.md](references/tracing.md)
- **Video recording**: [references/video-recording.md](references/video-recording.md)
