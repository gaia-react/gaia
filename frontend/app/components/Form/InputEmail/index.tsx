import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import InputText from '../InputText';
import type {InputProps} from '../types';

const InputEmail: FC<InputProps> = ({
  autoComplete = 'email',
  label,
  placeholder,
  ref,
  ...props
}) => {
  const {t} = useTranslation('common');

  return (
    <InputText
      ref={ref}
      autoComplete={autoComplete}
      label={label ?? t('email')}
      placeholder={placeholder ?? t('emailPlaceholder')}
      {...props}
    />
  );
};

export default InputEmail;
