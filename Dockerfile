# syntax=docker/dockerfile:1.7

FROM node:22.23.4-alpine3.23 AS base
WORKDIR /app
RUN apk upgrade --no-cache

FROM base AS dev
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY --chown=node:node . .
RUN sed -i 's/\r$//' /app/docker/dev-entrypoint.sh
USER node
CMD ["sh", "/app/docker/dev-entrypoint.sh"]

FROM base AS build
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM base AS production-deps
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev \
    && npm install --no-save --package-lock=false proxy-addr@2.0.8

FROM base AS production
ARG VERSION=1.0.0
LABEL org.opencontainers.image.title="fc4-desafio-docker-node-api" \
      org.opencontainers.image.description="Feature flags REST API built with Node.js and TypeScript" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="https://github.com/deividroger/fc4-desafio-docker-node-api"
ENV NODE_ENV=production
WORKDIR /app
COPY --from=production-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node docker/production-entrypoint.sh ./docker/production-entrypoint.sh
RUN sed -i 's/\r$//' /app/docker/production-entrypoint.sh
# npm is needed in the build stages, not at runtime; it also removes bundled vulnerable tar copies.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
ENTRYPOINT ["sh", "/app/docker/production-entrypoint.sh"]
CMD ["node", "dist/server.js"]
