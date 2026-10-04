import {createRoutesStub} from 'react-router';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import ThemeSwitch from '..';
import type {ThemeSwitchProps} from '..';

const renderSwitch = (userPreference?: ThemeSwitchProps['userPreference']) => {
  const Stub = createRoutesStub([
    {
      Component: () => <ThemeSwitch userPreference={userPreference} />,
      path: '/',
    },
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

  test('renders a lucide icon', async () => {
    renderSwitch('light');

    const button = await screen.findByRole('button');

    // Icons are aria-hidden, so the lucide class is the only handle on them.

    expect(button.querySelector('svg.lucide')).toBeInTheDocument();
  });

  test('posts the next theme mode', async () => {
    renderSwitch('light');

    await screen.findByRole('button');

    expect(screen.getByDisplayValue('dark')).toHaveAttribute('name', 'theme');
  });
});
