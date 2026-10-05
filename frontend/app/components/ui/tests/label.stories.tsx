import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Input} from '~/components/ui/input';
import {Label} from '~/components/ui/label';

const meta: Meta = {
  component: Label,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Label',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor="labelStoryInput">{t('email')}</Label>
      <Input id="labelStoryInput" type="email" />
    </div>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="group flex flex-col gap-2" data-disabled={true}>
      <Label htmlFor="labelStoryDisabledInput">{t('email')}</Label>
      <Input disabled={true} id="labelStoryDisabledInput" type="email" />
    </div>
  );
};
