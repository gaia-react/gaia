import type {ActionFunctionArgs} from 'react-router';
import {createRoutesStub} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';
import {setTimeout as delay} from 'node:timers/promises';
import {fireEvent, render, screen} from 'test/rtl';
import {ACTION_PATHS} from '~/action-paths';
import type * as languages from '~/languages';
import LanguageSelect from '..';

// The switcher renders nothing with one locale, so give it a second one.
vi.mock('~/languages', async (importOriginal) => ({
  ...(await importOriginal<typeof languages>()),
  LANGUAGES: ['en', 'ja'],
}));

// Long enough for a stray submission to reach the action before asserting none did.
const SETTLE_MILLISECONDS = 50;

const renderSelect = async (actionDelayMilliseconds = 0) => {
  const submitted = vi.fn<(language: FormDataEntryValue | null) => void>();

  const action = async ({request}: ActionFunctionArgs) => {
    const formData = await request.formData();

    if (actionDelayMilliseconds) await delay(actionDelayMilliseconds);

    submitted(formData.get('language'));

    return null;
  };

  const Stub = createRoutesStub([
    {Component: () => <LanguageSelect />, path: '/'},
    {action, path: ACTION_PATHS.setLanguage},
  ]);

  render(<Stub />);

  return {select: await screen.findByRole('combobox'), submitted};
};

// A closed native select changes value on Arrow keys (Windows browsers); jsdom
// does not, so the keyboard path is a keydown followed by the change it causes.
const arrowTo = (select: HTMLElement, value: string) => {
  fireEvent.keyDown(select, {key: 'ArrowDown'});
  fireEvent.change(select, {target: {value}});
};

describe('LanguageSelect', () => {
  test('a pointer choice submits immediately', async () => {
    const {selectOptions} = userEvent.setup();
    const {select, submitted} = await renderSelect();

    await selectOptions(select, 'ja');

    await vi.waitFor(() => {
      expect(submitted).toHaveBeenCalledExactlyOnceWith('ja');
    });
  });

  test('an arrow-key move does not submit', async () => {
    const {select, submitted} = await renderSelect();

    arrowTo(select, 'ja');

    await delay(SETTLE_MILLISECONDS);
    expect(submitted).not.toHaveBeenCalled();
  });

  test('Enter commits a keyboard choice', async () => {
    const {select, submitted} = await renderSelect();

    arrowTo(select, 'ja');
    fireEvent.keyDown(select, {key: 'Enter'});

    await vi.waitFor(() => {
      expect(submitted).toHaveBeenCalledExactlyOnceWith('ja');
    });
  });

  test('leaving the select commits a keyboard choice', async () => {
    const {select, submitted} = await renderSelect();

    arrowTo(select, 'ja');
    fireEvent.blur(select);

    await vi.waitFor(() => {
      expect(submitted).toHaveBeenCalledExactlyOnceWith('ja');
    });
  });

  test('leaving the select after Enter does not submit the choice again', async () => {
    const {select, submitted} = await renderSelect();

    arrowTo(select, 'ja');
    fireEvent.keyDown(select, {key: 'Enter'});
    fireEvent.blur(select);

    await delay(SETTLE_MILLISECONDS);
    expect(submitted).toHaveBeenCalledExactlyOnceWith('ja');
  });

  test('leaving the select back on the current language does not submit', async () => {
    const {select, submitted} = await renderSelect();

    arrowTo(select, 'ja');
    arrowTo(select, 'en');
    fireEvent.blur(select);

    await delay(SETTLE_MILLISECONDS);
    expect(submitted).not.toHaveBeenCalled();
  });

  test('a pointer choice after a keydown submits immediately', async () => {
    const {selectOptions} = userEvent.setup();
    const {select, submitted} = await renderSelect();

    fireEvent.keyDown(select, {key: 'ArrowDown'});
    await selectOptions(select, 'ja');

    await vi.waitFor(() => {
      expect(submitted).toHaveBeenCalledExactlyOnceWith('ja');
    });
  });

  test('a choice back to the current language during an in-flight submit is submitted', async () => {
    const {selectOptions} = userEvent.setup();
    const {select, submitted} = await renderSelect(SETTLE_MILLISECONDS);

    await selectOptions(select, 'ja');
    await selectOptions(select, 'en');

    await vi.waitFor(() => {
      expect(submitted).toHaveBeenLastCalledWith('en');
    });
  });
});
