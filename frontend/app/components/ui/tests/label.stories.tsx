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
      <Label htmlFor="label-story-input">{t('email')}</Label>
      <Input id="label-story-input" type="email" />
    </div>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="group flex flex-col gap-2" data-disabled={true}>
      <Label htmlFor="label-story-disabled-input">{t('email')}</Label>
      <Input disabled={true} id="label-story-disabled-input" type="email" />
    </div>
  );
};
