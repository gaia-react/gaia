import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, spyOn, waitFor, within} from 'storybook/test';
import {toast} from '~/components/ui/toast';
import {notify, NOTIFY_TYPES} from '~/utils/notify';
import {expectToast} from './expect-toast';
import stack from './stack';

// Raw palette utilities and arbitrary colors, which role tokens replace.
const RAW_PALETTE =
  /(bg|text|border|border-[trblxyse]|ring|ring-offset|outline|divide|placeholder|shadow|decoration|caret|accent|fill|stroke|from|via|to)-((slate|gray|zinc|neutral|stone|mauve|mist|olive|taupe|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d|white|black)|-\[(#|rgb|hsl|oklch)/;

// The toast renders in a portal on the document body, outside the canvas.
const getToastElement = (canvasElement: HTMLElement, text: string) =>
  within(canvasElement.ownerDocument.body)
    .getByText(text)
    .closest<HTMLElement>('[data-slot="toast"]') as HTMLElement;

// Toasts live in a module-level manager, so one story's toasts reach the next.
// Closing them and waiting for the exit animation keeps each story's toast
// count, and the axe scan after its play, to that story alone.
const clearToasts = async (): Promise<void> => {
  toast.close();
  await waitFor(async () => {
    await expect(
      document.body.querySelectorAll('[data-slot="toast"]')
    ).toHaveLength(0);
  });
};

const meta: Meta = {
  beforeEach: clearToasts,
  // The toast renders in a portal outside the canvas, so the canvas carries a
  // caption of its own: the story scan requires content in the story root.
  component: () => (
    <p className="text-sm">Notifications appear bottom right.</p>
  ),
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Utils/Notify',
};

export default meta;

export const ErrorToast: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.error({
      description: 'The server could not save your changes.',
      message: 'Something went wrong',
    });

    await expectToast(canvasElement, 'Something went wrong');
  },
};

export const Info: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.info({
      description: 'A new version of the app is available.',
      message: 'Update available',
    });

    await expectToast(canvasElement, 'Update available');
  },
};

export const Success: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.success({
      description: 'Your changes have been saved.',
      message: 'Saved',
    });

    await expectToast(canvasElement, 'Saved');
  },
};

export const Warning: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.warning('Your session expires in five minutes');

    await expectToast(canvasElement, 'Your session expires in five minutes');
  },
};

export const WithStack: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.error({
      message: JSON.stringify({
        description: 'The stack trace is logged to the console in development',
        message: 'Error with stack trace',
        stack,
      }),
    });

    await expectToast(canvasElement, 'Error with stack trace');
  },
};

export const StringAndDescriptionPayloads: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const body = within(canvasElement.ownerDocument.body);
    notify.info('plain string payload');
    notify.success({
      description: 'with description payload',
      message: 'Titled payload',
    });

    await waitFor(async () => {
      await expect(body.getByText('plain string payload')).toBeInTheDocument();
      await expect(body.getByText('Titled payload')).toBeInTheDocument();
      await expect(
        body.getByText('with description payload')
      ).toBeInTheDocument();
    });
  },
};

export const DescriptionOnlyPromoted: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.warning({description: 'only a description'});

    await expectToast(canvasElement, 'only a description');

    const toastElement = getToastElement(canvasElement, 'only a description');

    await expect(
      toastElement.querySelector('[data-slot="toast-title"]')
    ).toHaveTextContent('only a description');
    await expect(
      toastElement.querySelector('[data-slot="toast-description"]')
    ).toBeNull();
  },
};

export const EmptyMessagePromoted: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.warning({
      description: 'Saved empty message',
      message: '',
    });

    await expectToast(canvasElement, 'Saved empty message');

    const toastElement = getToastElement(canvasElement, 'Saved empty message');

    await expect(
      toastElement.querySelector('[data-slot="toast-title"]')
    ).toHaveTextContent('Saved empty message');
    await expect(
      toastElement.querySelector('[data-slot="toast-description"]')
    ).toBeNull();
  },
};

export const MessageRenderedAsText: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const markup = '<img src=x onerror="alert(1)">';
    notify.info(markup);

    await expectToast(canvasElement, markup);
    await expect(
      within(canvasElement.ownerDocument.body).queryByRole('img')
    ).not.toBeInTheDocument();
  },
};

export const DistinctIconPerType: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const glyphClasses: string[] = [];

    for (const type of NOTIFY_TYPES) {
      await clearToasts();
      notify[type](`${type} icon message`);

      await expectToast(canvasElement, `${type} icon message`);

      const icon = getToastElement(
        canvasElement,
        `${type} icon message`
      ).querySelector('[data-slot="toast-icon"] svg');

      await expect(icon).toHaveClass('lucide');

      // Only the glyph class (lucide-<name>) identifies the icon; the full
      // class string also carries per-type color classes.
      const glyph = [...(icon?.classList ?? [])].find((name) =>
        name.startsWith('lucide-')
      );

      await expect(glyph).toBeDefined();
      glyphClasses.push(glyph ?? '');
    }

    await expect(new Set(glyphClasses).size).toBe(NOTIFY_TYPES.length);
  },
};

export const RoleTokensNoRawPalette: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    for (const type of NOTIFY_TYPES) {
      await clearToasts();
      notify[type](`${type} token message`);

      await expectToast(canvasElement, `${type} token message`);

      // The per-type color classes sit on descendants (the error icon),
      // not the root. getAttribute, because an SVG's className is an
      // SVGAnimatedString rather than a string.
      const toastElement = getToastElement(
        canvasElement,
        `${type} token message`
      );

      const classes = [
        toastElement,
        ...toastElement.querySelectorAll('[class]'),
      ]
        .map((element) => element.getAttribute('class'))
        .join(' ');

      await expect(classes).not.toMatch(RAW_PALETTE);
    }
  },
};

export const ErrorIconDestructive: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.error('destructive error message');

    await expectToast(canvasElement, 'destructive error message');

    const errorIcon = getToastElement(
      canvasElement,
      'destructive error message'
    ).querySelector('[data-slot="toast-icon"] svg');

    await clearToasts();
    notify.info('plain info message');

    await expectToast(canvasElement, 'plain info message');

    const infoIcon = getToastElement(
      canvasElement,
      'plain info message'
    ).querySelector('[data-slot="toast-icon"] svg');

    await expect(errorIcon?.getAttribute('class')).toContain(
      'text-destructive'
    );
    await expect(infoIcon?.getAttribute('class')).not.toContain('destructive');
  },
};

export const SamePayloadUpdatesOneToast: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const body = within(canvasElement.ownerDocument.body);
    notify.info('repeat me payload');

    notify.info('repeat me payload');

    await expectToast(canvasElement, 'repeat me payload');
    await waitFor(async () => {
      await expect(body.getAllByText('repeat me payload')).toHaveLength(1);
    });
  },
};

export const ReturnsStableToastId: StoryObj<typeof meta> = {
  play: async () => {
    const first = notify.info('stable id payload');
    const second = notify.info('stable id payload');
    const different = notify.info('different id payload');

    await expect(first).toBe(second);
    await expect(different).not.toBe(first);
  },
};

export const ErrorDurationLongerByDefault: StoryObj<typeof meta> = {
  play: async () => {
    const addSpy = spyOn(toast, 'add');
    notify.error('slow default duration');
    notify.info('quick default duration');
    const errorTimeout = addSpy.mock.calls[0][0].timeout;
    const infoTimeout = addSpy.mock.calls[1][0].timeout;

    addSpy.mockRestore();
    await expect(errorTimeout).toBeGreaterThan(infoTimeout as number);
    await expect(errorTimeout).toBe(30_000);
    await expect(infoTimeout).toBe(5000);
  },
};

export const ExplicitDurationOverrides: StoryObj<typeof meta> = {
  play: async () => {
    // Longer than the error default and than any scan of this story: a
    // shorter value can close the toast while axe runs, and its exit state
    // trips aria-hidden-focus.
    const customDuration = 123_456;
    const addSpy = spyOn(toast, 'add');
    notify.error({duration: customDuration, message: 'custom duration'});
    const addedOptions = addSpy.mock.calls[0][0];

    addSpy.mockRestore();
    await expect(addedOptions).toMatchObject({timeout: customDuration});
  },
};

export const StackLoggedNotShown: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const consoleError = spyOn(console, 'error').mockImplementation(
      () => undefined
    );
    const body = within(canvasElement.ownerDocument.body);
    notify.error({
      message: JSON.stringify({
        description: 'Expand to view the stack',
        message: 'Stacked and logged',
        stack,
      }),
    });

    await expectToast(canvasElement, 'Stacked and logged');
    await expect(body.getByText('Expand to view the stack')).toBeVisible();

    // Production builds, which Chromatic snapshots, never log the stack.
    if (process.env.NODE_ENV === 'production') {
      await expect(consoleError).not.toHaveBeenCalledWith(stack);
    } else {
      await expect(consoleError).toHaveBeenCalledWith(stack);
    }
    // A substring check, so a stack rendered as one block still fails it.
    await expect(canvasElement.ownerDocument.body).not.toHaveTextContent(
      stack.split('\n', 1)[0]
    );
    consoleError.mockRestore();
  },
};
