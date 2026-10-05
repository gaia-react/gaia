import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';

type MarkerProps = {text: string};

const Marker = ({text}: MarkerProps) => <p>{text}</p>;

// Fixture for the test-identity extractor: a play on the meta is inherited by
// every story in the file. The play asserts the marker renders exactly once,
// which also proves the Chromatic light-and-dark decorator never engages inside
// the Vitest project (it renders every story twice).
const meta = {
  args: {text: 'meta play marker'},
  component: Marker,
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({args, canvasElement}) => {
    await expect(within(canvasElement).getAllByText(args.text)).toHaveLength(1);
  },
  title: 'Internal/CSF Meta Play',
} satisfies Meta<typeof Marker>;

export default meta;

type Story = StoryObj<typeof meta>;

export const InheritsMetaPlay: Story = {};
