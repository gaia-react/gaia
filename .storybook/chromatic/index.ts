import {DARK_MODE_EVENT_NAME} from '@vueless/storybook-dark-mode';
import isChromatic from 'chromatic/isChromatic';
import {addons} from 'storybook/preview-api';
import ToastDecorator from '../decorators/ToastDecorator';
import WrapDecorator from '../decorators/WrapDecorator';
import ChromaticDecorator from './decorator';

// render dark mode in chromatic snapshots
export const isChromaticSnapshot =
  isChromatic() ||
  (process.env.NODE_ENV === 'production' ?
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
    [...(window?.location.ancestorOrigins ?? {length: 0})].some((origin) =>
      origin.includes('www.chromatic.com')
    )
  : false);

if (!isChromaticSnapshot) {
  // listen for dark mode toggle changes
  const channel = addons.getChannel();
  channel.on(DARK_MODE_EVENT_NAME, (isDark: boolean) => {
    // eslint-disable-next-line unicorn/prevent-abbreviations
    const docsStory = document.querySelector('.docs-story');

    if (isDark) {
      document.documentElement.classList.add('dark');
      docsStory?.classList.add('bg-gray-900', 'text-white');
    } else {
      document.documentElement.classList.remove('dark');
      docsStory?.classList.remove('bg-gray-900', 'text-white');
    }
  });
}

export const decorators =
  isChromaticSnapshot ?
    [WrapDecorator, ChromaticDecorator, ToastDecorator]
  : [WrapDecorator, ToastDecorator];
