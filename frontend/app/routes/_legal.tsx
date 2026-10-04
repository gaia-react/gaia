import type {FC} from 'react';
import {Outlet} from 'react-router';
import Layout from '~/components/layout';

const LegalRoute: FC = () => (
  <Layout>
    <Outlet />
  </Layout>
);

export default LegalRoute;
