import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import InputText from '../InputText';
import type {InputProps} from '../types';

const InputPassword: FC<InputProps> = ({
  autoComplete = 'password',
  label,
  ref,
  ...props
}) => {
  const {t} = useTranslation('common');

  return (
    <InputText
      ref={ref}
      autoComplete={autoComplete}
      label={label ?? t('password')}
      {...props}
      placeholder="••••••••"
      type="password"
    />
  );
};

export default InputPassword;
