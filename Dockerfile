FROM node:22.19-alpine AS development-dependencies-env
RUN corepack enable
COPY . /app
WORKDIR /app
RUN pnpm install --frozen-lockfile

FROM node:22.19-alpine AS production-dependencies-env
RUN corepack enable
COPY ./package.json pnpm-lock.yaml /app/
WORKDIR /app
RUN pnpm install --frozen-lockfile --prod

FROM node:22.19-alpine AS build-env
RUN corepack enable
COPY . /app/
COPY --from=development-dependencies-env /app/node_modules /app/node_modules
WORKDIR /app
RUN pnpm build

FROM node:22.19-alpine
RUN corepack enable
COPY ./package.json pnpm-lock.yaml /app/
COPY --from=production-dependencies-env /app/node_modules /app/node_modules
COPY --from=build-env /app/build /app/build
WORKDIR /app
CMD ["pnpm", "start"]
