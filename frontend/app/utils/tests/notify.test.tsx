import {afterEach, describe, expect, test, vi} from 'vitest';
import {act, render, screen} from 'test/rtl';
import {toast, Toaster} from '~/components/ui/toast';
import {notify} from '../notify';
import stack from './stack';

// Raw palette utilities and arbitrary colors, which role tokens replace.
const RAW_PALETTE =
  /(bg|text|border|border-[trblxyse]|ring|ring-offset|outline|divide|placeholder|shadow|decoration|caret|accent|fill|stroke|from|via|to)-((slate|gray|zinc|neutral|stone|mauve|mist|olive|taupe|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d|white|black)|-\[(#|rgb|hsl|oklch)/;

const TYPES = ['error', 'info', 'success', 'warning'] as const;

const renderToaster = () => render(<Toaster />);

const fire = async (type: (typeof TYPES)[number]) => {
  await act(async () => {
    notify[type](`${type} message`);
  });

  const message = await screen.findByText(`${type} message`);

  return message.closest('[data-slot="toast"]') as HTMLElement;
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('notify', () => {
  test('renders a string payload and a description payload', async () => {
    renderToaster();

    await act(async () => {
      notify.info('plain string');
      notify.success({description: 'with description', message: 'Titled'});
    });

    expect(await screen.findByText('plain string')).toBeInTheDocument();
    expect(await screen.findByText('Titled')).toBeInTheDocument();
    expect(await screen.findByText('with description')).toBeInTheDocument();
  });

  test('promotes a description-only payload to the title', async () => {
    renderToaster();

    await act(async () => {
      notify.warning({description: 'only a description'});
    });

    expect(await screen.findByText('only a description')).toBeInTheDocument();
  });

  test('renders the message as text, never as HTML', async () => {
    renderToaster();
    const markup = '<img src=x onerror="alert(1)">';

    await act(async () => {
      notify.info(markup);
    });

    expect(await screen.findByText(markup)).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  test('every type renders a distinct lucide icon', async () => {
    renderToaster();

    const iconClasses: string[] = [];

    for (const type of TYPES) {
      const item = await fire(type);
      const icon = item.querySelector('[data-slot="toast-icon"] svg');

      expect(icon).toHaveClass('lucide');
      iconClasses.push(icon?.getAttribute('class') ?? '');
    }

    expect(new Set(iconClasses).size).toBe(TYPES.length);
  });

  test('toast surfaces use role tokens and no raw palette class', async () => {
    renderToaster();

    for (const type of TYPES) {
      const item = await fire(type);

      expect(item.className).not.toMatch(RAW_PALETTE);
    }
  });

  test('the error icon uses destructive and the others do not', async () => {
    renderToaster();

    const error = await fire('error');
    const info = await fire('info');
    const errorIcon = error.querySelector('[data-slot="toast-icon"] svg');
    const infoIcon = info.querySelector('[data-slot="toast-icon"] svg');

    expect(errorIcon?.getAttribute('class')).toContain('text-destructive');
    expect(infoIcon?.getAttribute('class')).not.toContain('destructive');
  });

  test('the same payload updates one toast instead of stacking', async () => {
    renderToaster();

    await act(async () => {
      notify.info('repeat me');
      notify.info('repeat me');
    });

    expect(await screen.findAllByText('repeat me')).toHaveLength(1);
  });

  test('returns the toast id, the same for the same payload', () => {
    const first = notify.info('stable');
    const second = notify.info('stable');

    expect(first).toBe(second);
    expect(notify.info('different')).not.toBe(first);
  });

  test('error toasts last longer than the other types by default', () => {
    const addSpy = vi.spyOn(toast, 'add');

    notify.error('slow');
    notify.info('quick');

    const errorTimeout = addSpy.mock.calls[0][0].timeout;
    const infoTimeout = addSpy.mock.calls[1][0].timeout;

    expect(errorTimeout).toBeGreaterThan(infoTimeout as number);
    expect(errorTimeout).toBe(30_000);
    expect(infoTimeout).toBe(5000);
  });

  test('an explicit duration overrides the default', () => {
    const addSpy = vi.spyOn(toast, 'add');

    notify.error({duration: 1234, message: 'custom'});

    expect(addSpy.mock.calls[0][0]).toMatchObject({timeout: 1234});
  });

  test('a payload with a stack logs it to the console and keeps it out of the toast', async () => {
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);
    renderToaster();

    await act(async () => {
      notify.error({
        message: JSON.stringify({
          description: 'Expand to view',
          message: 'Stacked',
          stack,
        }),
      });
    });

    expect(await screen.findByText('Stacked')).toBeInTheDocument();
    expect(screen.getByText('Expand to view')).toBeInTheDocument();
    expect(consoleError).toHaveBeenCalledWith(stack);
    expect(screen.queryByText(stack.split('\n', 1)[0])).not.toBeInTheDocument();
    consoleError.mockRestore();
  });
});
