FROM docker.io/library/node:lts-trixie-slim AS ext-deps
RUN --mount=type=bind,source=source-src/extensions,target=/tmp/extensions \
    mkdir -p /out && \
    for ext_dir in /tmp/extensions/*; do \
      if [ -d "$ext_dir" ] && [ -f "$ext_dir/package.json" ]; then \
        ext=$(basename "$ext_dir"); \
        mkdir -p "/out/$ext" && \
        cp "$ext_dir/package.json" "/out/$ext/package.json"; \
      fi; \
    done


FROM docker.io/library/node:lts-trixie-slim AS build
RUN npm install -g bun && corepack enable
WORKDIR /app
COPY source-src/package.json source-src/pnpm-lock.yaml source-src/pnpm-workspace.yaml source-src/.npmrc ./
COPY source-src/ui/package.json ./ui/package.json
COPY source-src/patches ./patches
COPY --from=ext-deps /out/ ./extensions/

RUN --mount=type=cache,id=openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile
COPY source-src/ .
RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done
RUN pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p src/canvas-host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > src/canvas-host/a2ui/a2ui.bundle.js && \
     echo "stub" > src/canvas-host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)
RUN pnpm build:docker
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build


FROM build AS runtime-assets
# RUN CI=true pnpm prune --prod && \
    # find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete
RUN find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete


FROM docker.io/library/node:lts-trixie-slim
WORKDIR /app

ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV OPENCLAW_BUNDLED_PLUGINS_DIR=/app/extensions
ENV COREPACK_HOME=/usr/local/share/corepack
ENV NODE_ENV=production
RUN --mount=type=cache,id=openclaw-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git lsof openssl wget ca-certificates zsh gh openssh-client \
      gnupg less tmux neovim jq ripgrep fd-find tree unzip tar strace xvfb \
      build-essential make python3 python3-pip python3-venv golang cargo rustc shellcheck \
      ffmpeg
RUN chown node:node /app
COPY --from=runtime-assets --chown=node:node /app/dist ./dist
COPY --from=runtime-assets --chown=node:node /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node /app/package.json .
COPY --from=runtime-assets --chown=node:node /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node /app/extensions ./extensions
COPY --from=runtime-assets --chown=node:node /app/skills ./skills
COPY --from=runtime-assets --chown=node:node /app/docs ./docs
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    for attempt in 1 2 3 4 5; do \
      if corepack prepare "$(node -p "require('./package.json').packageManager")" --activate; then break; fi; \
      if [ "$attempt" -eq 5 ]; then exit 1; fi; \
      sleep $((attempt * 2)); \
    done && \
    chmod -R a+rX "$COREPACK_HOME"
RUN --mount=type=cache,id=openclaw-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-apt-lists,target=/var/lib/apt,sharing=locked \
    mkdir -p /home/node/.cache/ms-playwright && \
    PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
    node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
    chown -R node:node /home/node/.cache/ms-playwright

RUN pnpm install -g @vector-im/matrix-bot-sdk

RUN git clone https://github.com/CortexReach/memory-lancedb-pro.git /app/extensions/memory-lancedb-pro && \
    cd /app/extensions/memory-lancedb-pro && \
    pnpm install && \
    chown node:node -R /app/extensions/memory-lancedb-pro
RUN git clone https://github.com/Martian-Engineering/lossless-claw.git /app/extensions/lossless-claw && \
    cd /app/extensions/lossless-claw && \
    pnpm install && \
    chown node:node -R /app/extensions/lossless-claw

WORKDIR /app
RUN pnpm i -g clawhub
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /app/openclaw.mjs
USER node

HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "openclaw.mjs", "gateway"]