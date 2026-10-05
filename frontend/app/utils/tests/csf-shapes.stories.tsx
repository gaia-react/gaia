import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';

type MarkerProps = {text: string};

const Marker = ({text}: MarkerProps) => <p>{text}</p>;

// Fixture for the test-identity extractor: one story per supported play shape.
// Each play asserts its marker renders exactly once, which also proves the
// Chromatic light-and-dark decorator never engages inside the Vitest project
// (it renders every story twice).
const meta = {
  args: {text: 'default marker'},
  component: Marker,
  parameters: {chromatic: {disableSnapshot: true}},
  title: 'Internal/CSF Shapes',
} satisfies Meta<typeof Marker>;

export default meta;

type Story = StoryObj<typeof meta>;

const expectMarkerOnce = async (
  canvasElement: HTMLElement,
  text: string
): Promise<void> => {
  await expect(within(canvasElement).getAllByText(text)).toHaveLength(1);
};

const sharedPlay: Story['play'] = async ({args, canvasElement}) => {
  await expectMarkerOnce(canvasElement, args.text);
};

const createStory = (text: string): Story => ({
  args: {text},
  play: async ({canvasElement}) => {
    await expectMarkerOnce(canvasElement, text);
  },
});

export const MultiWordObjectPlay: Story = {
  args: {text: 'object property marker'},
  play: async ({canvasElement}) => {
    await expectMarkerOnce(canvasElement, 'object property marker');
  },
};

export const RenamedStory: Story = {
  args: {text: 'renamed marker'},
  name: 'Custom Display Name',
  play: async ({canvasElement}) => {
    await expectMarkerOnce(canvasElement, 'renamed marker');
  },
};

export const AssignedPlay: Story = {args: {text: 'assigned marker'}};

AssignedPlay.play = async ({canvasElement}) => {
  await expectMarkerOnce(canvasElement, 'assigned marker');
};

export const SharedPlayFirst: Story = {
  args: {text: 'shared first marker'},
  play: sharedPlay,
};

export const SharedPlaySecond: Story = {
  args: {text: 'shared second marker'},
  play: sharedPlay,
};

export const FactoryBuilt: Story = createStory('factory marker');

export const SpreadStory: Story = {
  ...SharedPlayFirst,
  args: {text: 'spread marker'},
};

export const RenderOnly: Story = {args: {text: 'render only marker'}};
