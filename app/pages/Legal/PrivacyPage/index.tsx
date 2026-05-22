import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import Layout from '~/components/Layout';

type PrivacyPageProps = {
  description: string;
  title: string;
};

const PrivacyPage: FC<PrivacyPageProps> = ({description, title}) => {
  const {t} = useTranslation('pages', {keyPrefix: 'legal.privacy'});
  const raw = t('paragraphs', {returnObjects: true});
  const paragraphs = Array.isArray(raw) ? (raw as readonly string[]) : [];

  return (
    <Layout>
      <title>{title}</title>
      <meta content={description} name="description" />
      <div className="prose dark:prose-invert p-8 sm:px-16">
        <h1>{title}</h1>
        {paragraphs.map((paragraph) => (
          <p key={paragraph}>{paragraph}</p>
        ))}
      </div>
    </Layout>
  );
};

export default PrivacyPage;
