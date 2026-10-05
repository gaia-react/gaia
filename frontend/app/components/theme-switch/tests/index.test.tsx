import type {ActionFunctionArgs} from 'react-router';
import {createRoutesStub} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';
import {render, screen} from 'test/rtl';
import {ACTION_PATHS} from '~/action-paths';
import ThemeSwitch from '..';
import type {ThemeSwitchProps} from '..';

const renderSwitch = (
  userPreference?: ThemeSwitchProps['userPreference'],
  action: (args: ActionFunctionArgs) => unknown = () => null
) => {
  const Stub = createRoutesStub([
    {
      Component: () => <ThemeSwitch userPreference={userPreference} />,
      path: '/',
    },
    {action, path: ACTION_PATHS.themeSwitch},
  ]);

  return render(<Stub />);
};

describe('ThemeSwitch', () => {
  test.each([
    [undefined, 'Enable light mode'],
    ['light', 'Enable dark mode'],
    ['dark', 'Use system theme'],
  ] as const)('preference %s names the button %s', async (preference, name) => {
    renderSwitch(preference);

    expect(await screen.findByRole('button', {name})).toBeInTheDocument();
  });

  test.each([
    [undefined, 'monitor'],
    ['light', 'sun'],
    ['dark', 'moon'],
  ] as const)('preference %s renders the %s icon', async (preference, icon) => {
    renderSwitch(preference);

    const button = await screen.findByRole('button');

    // Icons are aria-hidden, so the lucide class is the only handle on them.
    // eslint-disable-next-line testing-library/no-node-access
    expect(button.querySelector(`svg.lucide-${icon}`)).toBeInTheDocument();
  });

  test.each([
    [undefined, 'light'],
    ['light', 'dark'],
    ['dark', 'system'],
  ] as const)(
    'preference %s posts theme %s on click',
    async (preference, next) => {
      const {click} = userEvent.setup();
      const submitted = vi.fn<(theme: FormDataEntryValue | null) => void>();
      renderSwitch(preference, async ({request}) => {
        const formData = await request.formData();
        submitted(formData.get('theme'));

        return null;
      });

      await click(await screen.findByRole('button'));

      await vi.waitFor(() => {
        expect(submitted).toHaveBeenCalledExactlyOnceWith(next);
      });
    }
  );
});
