---
paths:
  - 'app/**/*.tsx'
  - 'app/**/*.css'
---

# Tailwind Conventions

Authoring patterns live in `.claude/skills/tailwind/SKILL.md`. This rule covers only project-specific facts.

## Tailwind v4

Config lives in `app/styles/tailwind.css` under `@theme` / `@layer` / `@utility`. There is no `tailwind.config.ts`.

## Dark mode

Class strategy: `@custom-variant dark (&:where(.dark, .dark *))`. Always pair light/dark in one utility call (`bg-white dark:bg-gray-900`).

Prefer the project's semantic `@utility` tokens over raw paired classes:

| Token              | Expands to                             |
| ------------------ | -------------------------------------- |
| `bg-body`          | `bg-white dark:bg-gray-900`            |
| `bg-secondary`     | `bg-gray-100 dark:bg-gray-800`         |
| `text-body`        | `text-gray-900 dark:text-white`        |
| `text-secondary`   | `text-gray-500 dark:text-gray-400`     |
| `text-disabled`    | `text-gray-900/15 dark:text-white/15`  |
| `text-placeholder` | `text-gray-400 dark:text-gray-600`     |
| `text-invalid`     | `text-red-600 dark:text-red-500`       |
| `border-normal`    | `border-gray-300 dark:border-gray-600` |
| `border-strong`    | `border-gray-400 dark:border-gray-500` |
| `border-medium`    | `border-gray-200 dark:border-gray-700` |
| `border-light`     | `border-gray-100 dark:border-gray-800` |
| `border-disabled`  | `border-gray-300 dark:border-gray-700` |
| `input-invalid`    | error ring + border combo              |

## Responsive breakpoint

`sm:` (≥ 640 px) is the only breakpoint used in component code. Order mobile-first: base → `sm:` → `md:` → `lg:`.

## No arbitrary colors

Use palette tokens (`blue-500`, `red-600`) with opacity modifiers (`bg-blue-900/15`). No hex literals in `[]`.
