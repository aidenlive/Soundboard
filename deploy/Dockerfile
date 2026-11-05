# Two targets, built from the repository root (see deploy/compose.yaml).
#   engine: builds the engine on Debian, runs its tests and the routing prototype.
#   site:   serves public/ with tools/site/serve.mjs (no dependencies).

FROM debian:bookworm-slim AS engine
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake g++ make \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY engine ./engine
RUN cmake -S engine -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
CMD ["sh", "-c", "ctest --test-dir build --output-on-failure && mkdir -p /out && build/sbe_routing_demo /out"]

FROM node:22-alpine AS site
WORKDIR /srv
COPY public ./public
COPY tools/site/serve.mjs ./serve.mjs
ENV SITE_ROOT=/srv/public SITE_HOST=0.0.0.0 SITE_PORT=8052
EXPOSE 8052
USER node
CMD ["node", "serve.mjs"]
