import type {FC} from 'react';
import {Outlet} from 'react-router';
import Layout from '~/components/layout';

// This is where routes that are publicly available go
const PublicRoute: FC = () => (
  <Layout>
    <Outlet />
  </Layout>
);

export default PublicRoute;
