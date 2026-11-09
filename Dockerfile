# syntax=docker/dockerfile:1
#
# ContainerOps Dashboard - production image
# Repository: Container-Orchestration
#
# Stage 1 (deps)    : install production dependencies reproducibly with npm ci
# Stage 2 (runtime) : minimal image with only node, node_modules and app code

ARG NODE_IMAGE=node:22.23.4-alpine3.24

# ---------------------------------------------------------------------------
# Stage 1: dependency installation
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps

WORKDIR /build

# Copy ONLY the dependency manifests first. This layer (and the npm ci layer
# below) stays cached until package.json / package-lock.json change, so editing
# application source does not trigger a dependency reinstall.
COPY package.json package-lock.json ./

# npm ci: exact versions from the lockfile; --omit=dev: production only.
# The BuildKit cache mount keeps npm's download cache out of the image layers.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

LABEL org.opencontainers.image.title="ContainerOps Dashboard" \
      org.opencontainers.image.description="Week 04 Containerization & Orchestration demo app" \
      org.opencontainers.image.source="Container-Orchestration" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PORT=3000

# Remove package managers that the running app never needs (smaller image,
# fewer binaries for an attacker to abuse), then create a dedicated,
# unprivileged system user and group with a fixed UID/GID.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg \
 && addgroup -S -g 10001 appgroup \
 && adduser  -S -D -H -u 10001 -G appgroup -s /sbin/nologin appuser

WORKDIR /app

# Files are owned by root and are read-only for the app user: the process can
# read its code but cannot modify it at runtime.
COPY --from=deps --chown=root:root /build/node_modules ./node_modules
COPY --chown=root:root --chmod=644 package.json ./
COPY --chown=root:root --chmod=u=rwX,go=rX app ./app

USER appuser:appgroup

EXPOSE 3000

# Uses Node's built-in http module, so curl/wget are not required.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "app/healthcheck.js"]

# Exec form: node is the main process and receives SIGTERM/SIGINT directly.
CMD ["node", "app/server.js"]
