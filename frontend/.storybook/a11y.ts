import {AXE_WCAG_TAGS} from '../test/axe-tags';

// Any impact fails here, where the Playwright scan fails only critical and
// serious. `region` is off because a story renders a fragment outside the page
// landmarks. Kept out of preview.ts so the a11y opt-out guard can resolve story
// parameters without importing the preview's stylesheet.
const a11y = {
  config: {rules: [{enabled: false, id: 'region'}]},
  options: {
    runOnly: {
      type: 'tag',
      values: AXE_WCAG_TAGS,
    },
  },
  test: 'error',
};

export default a11y;
