import type {Meta, StoryObj} from '@storybook/react-vite';
import {http, HttpResponse} from 'msw';
import {expect, within} from 'storybook/test';
import {url} from 'test/mocks/url';
import {ITEMS_URLS} from '~/services/gaia/items';
import ItemNames from '..';

// Both stories read the same query key from different handlers. Run in this
// order, the second story fails if it inherits the first story's cache.
const meta: Meta<typeof ItemNames> = {
  component: ItemNames,
  title: 'Fixtures/ItemNames/HandlerBFirst',
};

export default meta;

type Story = StoryObj<typeof ItemNames>;

export const HandlerB: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get(url(ITEMS_URLS.items), () =>
          HttpResponse.json({data: [{display_name: 'Handler B item', id: 'b'}]})
        ),
      ],
    },
  },
  play: async ({canvasElement}) => {
    const canvas = within(canvasElement);

    await expect(await canvas.findByText('Handler B item')).toBeInTheDocument();
    await expect(canvas.queryByText('Handler A item')).not.toBeInTheDocument();
  },
};

export const HandlerA: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get(url(ITEMS_URLS.items), () =>
          HttpResponse.json({data: [{display_name: 'Handler A item', id: 'a'}]})
        ),
      ],
    },
  },
  play: async ({canvasElement}) => {
    const canvas = within(canvasElement);

    await expect(await canvas.findByText('Handler A item')).toBeInTheDocument();
    await expect(canvas.queryByText('Handler B item')).not.toBeInTheDocument();
  },
};
