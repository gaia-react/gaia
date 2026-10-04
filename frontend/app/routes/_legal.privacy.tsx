import type {FC} from 'react';
import {useLoaderData} from 'react-router';
import {getInstance} from '~/middleware/i18next';
import PrivacyPage from '~/pages/privacy/page';
import type {Route} from './+types/_legal.privacy';

export const loader = async ({context}: Route.LoaderArgs) => {
  const i18next = getInstance(context);
  const title = i18next.t('legal.privacy.title', {ns: 'pages'});
  const description = i18next.t('legal.privacy.description', {ns: 'pages'});

  return {description, title};
};

const PrivacyRoute: FC = () => {
  const {description, title} = useLoaderData<typeof loader>();

  return <PrivacyPage description={description} title={title} />;
};

export default PrivacyRoute;
