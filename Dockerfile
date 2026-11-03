# One image for the whole app (docs/railway-deployment.md): Rails serves the API and the built
# frontend from one origin. Railway builds this file automatically; it holds no secrets.

FROM node:22-slim AS frontend
WORKDIR /app
COPY package.json package-lock.json tsconfig.json tsconfig.app.json tsconfig.node.json vite.config.ts index.html ./
COPY public public
COPY src src
RUN npm ci && VITE_RUNOUT_API_URL=/api npm run build

FROM ruby:3.4.7-slim AS gems
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev pkg-config
WORKDIR /rails
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test BUNDLE_PATH=/usr/local/bundle
COPY server/Gemfile server/Gemfile.lock server/.ruby-version ./
RUN bundle install && rm -rf /usr/local/bundle/ruby/*/cache

FROM ruby:3.4.7-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends libpq5 libjemalloc2 libyaml-0-2 \
  && rm -rf /var/lib/apt/lists/* && ln -s /usr/lib/*-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so.2
WORKDIR /rails
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test BUNDLE_PATH=/usr/local/bundle \
    RAILS_LOG_LEVEL=info SOLID_QUEUE_IN_PUMA=async
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY server/ ./
# Vite's assets go in public/ for Rails' static server. index.html stays outside it, so
# FrontendController can serve it without the far-future cache header digested assets get.
COPY --from=frontend /app/dist/ public/
RUN mkdir frontend && mv public/index.html frontend/index.html \
  && bundle exec bootsnap precompile --gemfile app/ lib/ \
  && useradd --create-home --uid 1000 rails && mkdir -p tmp log && chown -R rails:rails tmp log
USER rails
CMD ["bin/docker-entrypoint"]
