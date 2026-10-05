import type {KeyboardEventHandler} from 'react';
import {useRef} from 'react';
import {useTranslation} from 'react-i18next';
import {useFetcher, useLocation} from 'react-router';
import {cn} from 'cn';
import {ACTION_PATHS} from '~/action-paths';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {LANGUAGES} from '~/languages';

// Native select intentional: this is a non-Conform chrome control, not a form field.
const LANGUAGE_LABELS: Record<string, string> = {en: 'English'};

type LanguageSelectProps = {
  className?: string;
  languages?: readonly string[];
  onChange?: () => void;
};

const LanguageSelect = ({
  className,
  languages = LANGUAGES,
  onChange,
}: LanguageSelectProps) => {
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
  // a choice is compared against the last one submitted, never the current
  // language: that would drop a pick back to it made while a submission is in
  // flight, and an Enter commit followed by leaving the select would submit twice.
  const submittedLanguageRef = useRef(language);

  // A single configured language offers nothing to switch, so render nothing.
  // The switcher appears once a second locale is added (LANGUAGES grows via the
  // add-locale runbook).
  if (languages.length <= 1) return undefined;

  const options = languages.map((value) => ({
    label: LANGUAGE_LABELS[value] ?? value,
    value,
  }));

  const redirectUrl = `${location.pathname}${location.search}${location.hash}`;

  const submitLanguage = async () => {
    const form = formRef.current;

    if (!form) return;

    const selectedLanguage = String(new FormData(form).get('language'));

    if (selectedLanguage === submittedLanguageRef.current) return;

    submittedLanguageRef.current = selectedLanguage;
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

  const handleKeyDownSelect: KeyboardEventHandler<HTMLSelectElement> = async (
    event
  ) => {
    isKeyboardInputRef.current = true;

    if (event.key === 'Enter') await submitLanguage();
  };

  const handlePointerDownSelect = () => {
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
        onKeyDown={handleKeyDownSelect}
        onPointerDown={handlePointerDownSelect}
        size="sm"
      >
        {options.map(({label, value}) => (
          <NativeSelectOption key={value} value={value}>
            {label}
          </NativeSelectOption>
        ))}
      </NativeSelect>
    </fetcher.Form>
  );
};

export default LanguageSelect;
