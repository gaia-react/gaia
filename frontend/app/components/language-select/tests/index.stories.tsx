import type {Meta, StoryObj} from '@storybook/react-vite';
import {
  expect,
  fireEvent,
  fn,
  userEvent,
  waitFor,
  within,
} from 'storybook/test';
import stubs from 'test/stubs';
import {ACTION_PATHS} from '~/action-paths';
import LanguageSelect from '..';

type StoryArgs = {
  actionDelayMilliseconds: number;
  languages: string[];
  onSubmit: (language: FormDataEntryValue | null) => void;
};

const meta: Meta<StoryArgs> = {
  args: {
    actionDelayMilliseconds: 0,
    languages: ['en', 'ja'],
    onSubmit: fn(),
  },
  component: LanguageSelect,
  decorators: [
    stubs.reactRouter(({args}) => ({
      actions: {
        [ACTION_PATHS.setLanguage]: async ({request}) => {
          const formData = await request.formData();

          if (args.actionDelayMilliseconds) {
            await new Promise((resolve) => {
              setTimeout(resolve, args.actionDelayMilliseconds);
            });
          }

          args.onSubmit(formData.get('language'));

          return null;
        },
      },
    })),
  ],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  render: ({languages}) => <LanguageSelect languages={languages} />,
  title: 'Components/LanguageSelect',
};

export default meta;

type Story = StoryObj<StoryArgs>;

// Long enough for a stray submission to reach the action before asserting none did.
const SETTLE_MILLISECONDS = 50;

const settle = async () =>
  new Promise((resolve) => {
    setTimeout(resolve, SETTLE_MILLISECONDS);
  });

const findSelect = async (canvasElement: HTMLElement) =>
  within(canvasElement).findByRole('combobox', {name: 'Language'});

// A closed native select changes value on Arrow keys (Windows browsers), and
// Chromium's closed-select arrow behavior is platform-dependent, so the keyboard
// path is a keydown followed by the change it causes.
const arrowTo = async (select: HTMLElement, value: string) => {
  await fireEvent.keyDown(select, {key: 'ArrowDown'});
  await fireEvent.change(select, {target: {value}});
};

const expectSubmittedOnce = async (
  onSubmit: StoryArgs['onSubmit'],
  language: string
) => {
  await waitFor(async () => {
    await expect(onSubmit).toHaveBeenCalledTimes(1);
  });
  await expect(onSubmit).toHaveBeenCalledWith(language);
};

export const Default: Story = {};

export const PointerChoiceSubmits: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await userEvent.selectOptions(select, 'ja');

    await expectSubmittedOnce(args.onSubmit, 'ja');
  },
};

export const ArrowKeyMoveDoesNotSubmit: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await arrowTo(select, 'ja');

    await settle();
    await expect(args.onSubmit).not.toHaveBeenCalled();
  },
};

export const CommitsOnEnter: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await userEvent.tab();
    await expect(select).toHaveFocus();
    await arrowTo(select, 'ja');
    await userEvent.keyboard('{Enter}');

    await expectSubmittedOnce(args.onSubmit, 'ja');
  },
};

export const CommitsOnLeaving: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await userEvent.tab();
    await expect(select).toHaveFocus();
    await arrowTo(select, 'ja');
    await userEvent.tab();
    await expect(select).not.toHaveFocus();

    await expectSubmittedOnce(args.onSubmit, 'ja');
  },
};

export const EnterThenLeaveSubmitsOnce: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    select.focus();
    await arrowTo(select, 'ja');
    await userEvent.keyboard('{Enter}');
    await expectSubmittedOnce(args.onSubmit, 'ja');
    await userEvent.tab();

    await settle();
    await expect(args.onSubmit).toHaveBeenCalledTimes(1);
  },
};

export const LeavingBackOnCurrentLanguageDoesNotSubmit: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    select.focus();
    await arrowTo(select, 'ja');
    await arrowTo(select, 'en');
    await userEvent.tab();

    await settle();
    await expect(args.onSubmit).not.toHaveBeenCalled();
  },
};

export const PointerChoiceAfterKeydownSubmits: Story = {
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await fireEvent.keyDown(select, {key: 'ArrowDown'});
    await userEvent.selectOptions(select, 'ja');

    await expectSubmittedOnce(args.onSubmit, 'ja');
  },
};

export const ChoiceBackToCurrentDuringInFlightSubmit: Story = {
  args: {actionDelayMilliseconds: SETTLE_MILLISECONDS},
  play: async ({args, canvasElement}) => {
    const select = await findSelect(canvasElement);

    await userEvent.selectOptions(select, 'ja');
    await userEvent.selectOptions(select, 'en');

    await waitFor(async () => {
      await expect(args.onSubmit).toHaveBeenLastCalledWith('en');
    });
  },
};
