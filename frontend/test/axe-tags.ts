/**
 * The axe tag set every accessibility scan runs: WCAG 2.0 and 2.1, levels A
 * and AA. The Storybook preview and the Playwright helpers both import it, so
 * one edit moves the story gate and the page scan together.
 */
export const AXE_WCAG_TAGS: string[] = [
  'wcag2a',
  'wcag2aa',
  'wcag21a',
  'wcag21aa',
];
