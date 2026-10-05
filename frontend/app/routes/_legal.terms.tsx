import {useLoaderData} from 'react-router';
import {getInstance} from '~/middleware/i18next';
import TermsPage from '~/pages/terms/page';
import type {Route} from './+types/_legal.terms';

export const loader = async ({context}: Route.LoaderArgs) => {
  const i18next = getInstance(context);
  const title = i18next.t('legal.terms.title', {ns: 'pages'});
  const description = i18next.t('legal.terms.description', {ns: 'pages'});

  return {description, title};
};

const TermsRoute = () => {
  const {description, title} = useLoaderData<typeof loader>();

  return <TermsPage description={description} title={title} />;
};

export default TermsRoute;
