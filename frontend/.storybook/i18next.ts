import {initReactI18next} from 'react-i18next';
import i18next from 'i18next';
import i18n from '~/i18n';

await i18next.use(initReactI18next).init({
  ...i18n,
  lng: 'en',
  ns: ['common'],
});

export default i18next;
