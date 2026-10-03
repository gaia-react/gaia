import type {FC} from 'react';
import {Outlet} from 'react-router';
import Layout from '~/components/Layout';

const LegalRoute: FC = () => (
  <Layout>
    <Outlet />
  </Layout>
);

export default LegalRoute;
