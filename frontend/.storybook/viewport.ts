/* eslint-disable perfectionist/sort-objects */
const viewport = {
  viewports: {
    landscape: {
      name: 'Landscape',
      right: 'lg',
      styles: {
        height: '768px',
        width: '1024px',
      },
      type: 'tablet',
    },
    portrait: {
      name: 'Portrait',
      right: 'md',
      styles: {
        height: '1024px',
        width: '768px',
      },
      type: 'tablet',
    },
    mobileLarge: {
      name: 'Large mobile',
      right: 'sm',
      styles: {
        height: '846px',
        width: '390px',
      },
      type: 'mobile',
    },
    mobileSmall: {
      name: 'Small mobile',
      right: '',
      styles: {
        height: '812px',
        width: '375px',
      },
      type: 'mobile',
    },
  },
};

export default viewport;
