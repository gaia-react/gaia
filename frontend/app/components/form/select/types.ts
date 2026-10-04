import type {Option} from '../types';

export type SelectOption = (SelectOptionWithOptions | SelectOptionWithValue) & {
  disabled?: boolean;
  label: string;
};

type SelectOptionWithOptions = {
  options: Option[];
  value?: never;
};

type SelectOptionWithValue = {
  options?: never;
  value: string;
};
