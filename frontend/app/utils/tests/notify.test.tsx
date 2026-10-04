import {createRoutesStub} from 'react-router';
import {toast} from 'sonner';
import {afterEach, describe, expect, test, vi} from 'vitest';
import {act, render, screen} from 'test/rtl';
import {Toaster} from '~/components/ui/sonner';
import {notify, toasterProps} from '../notify';
import stack from './stack';

// UAT palette check: raw palette utilities and arbitrary colors.
const RAW_PALETTE =
  /(bg|text|border|border-[trblxyse]|ring|ring-offset|outline|divide|placeholder|shadow|decoration|caret|accent|fill|stroke|from|via|to)-((slate|gray|zinc|neutral|stone|mauve|mist|olive|taupe|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d|white|black)|-\[(#|rgb|hsl|oklch)/;

const TYPES = ['error', 'info', 'success', 'warning'] as const;

const ToasterStub = createRoutesStub([
  {Component: () => <Toaster {...toasterProps} />, path: '/'},
]);

const renderToaster = () => render(<ToasterStub initialEntries={['/']} />);

const fire = async (type: (typeof TYPES)[number]) => {
  await act(async () => {
    notify[type](`${type} message`);
  });

  const message = await screen.findByText(`${type} message`);

  return message.closest('li') as HTMLElement;
};

afterEach(() => {
  act(() => {
    toast.dismiss();
  });
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
      const icon = item.querySelector('[data-icon] svg');

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

  test('keeps the vendored toast class after the toasterProps spread', async () => {
    renderToaster();

    const item = await fire('info');

    expect(item).toHaveClass('cn-toast');
  });

  test('the error toast uses destructive and the others do not', async () => {
    renderToaster();

    const error = await fire('error');
    const info = await fire('info');

    expect(error.className).toContain('destructive');
    expect(info.className).not.toContain('destructive');
  });

  test('error toasts last longer than the other types by default', () => {
    const errorSpy = vi.spyOn(toast, 'error');
    const infoSpy = vi.spyOn(toast, 'info');

    notify.error('slow');
    notify.info('quick');

    const errorDuration = (errorSpy.mock.calls[0][1] as {duration: number})
      .duration;
    const infoDuration = (infoSpy.mock.calls[0][1] as {duration: number})
      .duration;

    expect(errorDuration).toBeGreaterThan(infoDuration);
    expect(errorDuration).toBe(30_000);
    expect(infoDuration).toBe(5000);
  });

  test('an explicit duration overrides the default', () => {
    const errorSpy = vi.spyOn(toast, 'error');

    notify.error({duration: 1234, message: 'custom'});

    expect(errorSpy.mock.calls[0][1]).toMatchObject({duration: 1234});
  });

  test('a payload with a stack renders it in the description', async () => {
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
    expect(screen.getByText('Stack trace')).toBeInTheDocument();
  });
});
