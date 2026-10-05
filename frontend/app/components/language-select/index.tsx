import type {KeyboardEvent} from 'react';
import {useRef} from 'react';
import {useTranslation} from 'react-i18next';
import {useFetcher, useLocation} from 'react-router';
import {cn} from 'cn';
import {ACTION_PATHS} from '~/action-paths';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {LANGUAGES} from '~/languages';

// Native select intentional: this is a non-Conform chrome control, not a form field.
const LANGUAGE_LABELS: Record<string, string> = {en: 'English'};
const OPTIONS = LANGUAGES.map((value) => ({
  label: LANGUAGE_LABELS[value] ?? value,
  value,
}));

type LanguageSelectProps = {
  className?: string;
  onChange?: () => void;
};

const LanguageSelect = ({className, onChange}: LanguageSelectProps) => {
  const {
    i18n: {language},
    t,
  } = useTranslation();

  const fetcher = useFetcher();
  const location = useLocation();
  const formRef = useRef<HTMLFormElement>(null);
  // A closed native select changes value on Arrow keys in Windows browsers, so a
  // keyboard change only stages the choice and Enter or leaving the select
  // commits it (WCAG 3.2.2 On Input). A pointer change is already a committed
  // choice and submits at once.
  const isKeyboardInputRef = useRef(false);
  // The current language updates only after the action reloads translations, so
  // without this an Enter commit followed by leaving the select submits twice.
  const submittedLanguageRef = useRef(language);

  // A single configured language offers nothing to switch, so render nothing.
  // The switcher appears once a second locale is added (LANGUAGES grows via the
  // add-locale runbook).
  if (LANGUAGES.length <= 1) return undefined;

  const redirectUrl = `${location.pathname}${location.search}${location.hash}`;

  const submitLanguage = async () => {
    const form = formRef.current;

    if (!form) return;

    const selected = String(new FormData(form).get('language'));

    if (selected === language || selected === submittedLanguageRef.current) {
      return;
    }

    submittedLanguageRef.current = selected;
    await fetcher.submit(form, {
      action: ACTION_PATHS.setLanguage,
      method: 'POST',
    });

    onChange?.();
  };

  const handleChangeLanguageForm = async () => {
    if (isKeyboardInputRef.current) return;

    await submitLanguage();
  };

  const handleKeyDown = async (event: KeyboardEvent<HTMLSelectElement>) => {
    isKeyboardInputRef.current = true;

    if (event.key === 'Enter') await submitLanguage();
  };

  const handlePointerDown = () => {
    isKeyboardInputRef.current = false;
  };

  return (
    <fetcher.Form
      ref={formRef}
      action={ACTION_PATHS.setLanguage}
      className={cn('flex-none', className)}
      method="POST"
      onChange={handleChangeLanguageForm}
    >
      <input name="redirectUrl" type="hidden" value={redirectUrl} />
      <NativeSelect
        aria-label={t('language')}
        defaultValue={language}
        name="language"
        onBlur={submitLanguage}
        onKeyDown={handleKeyDown}
        onPointerDown={handlePointerDown}
        size="sm"
      >
        {OPTIONS.map(({label, value}) => (
          <NativeSelectOption key={value} value={value}>
            {label}
          </NativeSelectOption>
        ))}
      </NativeSelect>
    </fetcher.Form>
  );
};

export default LanguageSelect;
