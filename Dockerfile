# The yolo box: an isolated environment for the claude-code CLI. Adds
# Playwright/Chromium, postgres + ssh for the agent's tooling, and a non-root
# `claude` user whose UID/GID are aligned with the host so bind mounts stay
# writeable.
#
# Everything this shares with rhizome's plain dev box lives in the `base` stage
# of ../rhizome/docker/Dockerfile: the toolchain, the sqlite-vec install,
# VEC_PATH / VEC_URL, /etc/rhizome-use-ollama, the entrypoint, and the git-push
# block. `FROM base AS yolo` cannot cross files, so run.sh builds that stage
# from the rhizome checkout first and tags it, and this file starts from the tag.
#
# WITH_VEC is a build arg to `base`, so the tag has to encode it -- otherwise a
# novec base built for an earlier run would be silently reused for a WITH_VEC=1
# one, and the box would come up with no vec0.so and no ollama bridge. run.sh
# sets BASE_TAG to vec / novec to match and passes it in here.
ARG BASE_TAG=novec
FROM rhizome-base:${BASE_TAG}

ARG USER_UID=501
ARG USER_GID=20

# Block `git push` from inside the container. This belongs here and not in
# `base`: the plain dev box a human drives should not silently refuse to push,
# but an agent should, because pushing is the one git operation whose blast
# radius leaves the machine. Committing and merging (including on main) stay
# allowed -- in-box commits are traceable via the git identity baked in below.
RUN printf '#!/bin/sh\ncase "$1" in\n  push)\n    echo "git push is disabled inside the docker container." >&2\n    exit 1\n    ;;\nesac\nexec /usr/bin/git "$@"\n' > /usr/local/bin/git \
 && chmod +x /usr/local/bin/git

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    postgresql-client \
    sudo \
    chromium \
    libnss3 \
    libfreetype6 \
    libharfbuzz0b \
    fonts-freefont-ttf \
    fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/*

# Debian's chromium (>=150) dies with SIGTRAP (a compiled-in CHECK) under
# Docker Desktop's linuxkit kernel, so all in-box browser work (Playwright
# MCP, make e2e) uses Playwright's own chromium build instead. It is baked
# into the image at a fixed path below and reached via the stable
# /usr/local/bin/pw-chromium symlink; the Debian chromium package stays
# installed purely to pull in the browser runtime dependencies.
# Keep in lockstep with @playwright/test in ../rhizome/package.json.
ARG PLAYWRIGHT_VERSION=1.61.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN mkdir -p /opt/ms-playwright /tmp/pwsetup && cd /tmp/pwsetup \
 && npm init -y >/dev/null \
 && npm install playwright-core@${PLAYWRIGHT_VERSION} >/dev/null \
 && npx playwright-core install chromium-headless-shell \
 && rm -rf /tmp/pwsetup \
 && ln -s "$(find /opt/ms-playwright -type f -name headless_shell | head -1)" /usr/local/bin/pw-chromium \
 && chmod -R a+rX /opt/ms-playwright \
 && echo "${PLAYWRIGHT_VERSION}" > /opt/ms-playwright/PLAYWRIGHT_VERSION \
 && /usr/local/bin/pw-chromium --version

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/local/bin/pw-chromium \
    PATH="/opt/java/openjdk/bin:${PATH}"

# Java profile script so login shells (and the claude-code wrapper) see JAVA_HOME.
RUN printf 'export JAVA_HOME=/opt/java/openjdk\nexport PATH=$JAVA_HOME/bin:$PATH\n' > /etc/profile.d/java.sh

# Always pass --dangerously-skip-permissions when invoked inside the sandbox.
# Pinned; bump deliberately rather than riding npm latest.
ARG CLAUDE_CODE_VERSION=2.1.257
# --prefix /usr/local: NodeSource's npm globals default to /usr (Debian's
# patched npm used /usr/local), and the wrapper below expects /usr/local/bin.
RUN npm install -g --prefix /usr/local @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && mv /usr/local/bin/claude /usr/local/bin/claude-bin \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude-bin --dangerously-skip-permissions "$@"\n' > /usr/local/bin/claude \
 && chmod +x /usr/local/bin/claude

# @playwright/mcp as a pinned global, which is what lets .mcp.json say
# `playwright-mcp` instead of `npx @playwright/mcp@latest`. npx re-resolves
# `@latest` against the npm registry on *every* startup, and locked mode
# (docker-compose.locked.yml) blocks the registry -- so the old form would take
# the browser MCP server down with it. Same pin as ../docker/Dockerfile so both
# boxes run the same server. --prefix /usr/local for the same reason as
# claude-code above.
ARG PLAYWRIGHT_MCP_VERSION=0.0.75
RUN npm install -g --prefix /usr/local @playwright/mcp@${PLAYWRIGHT_MCP_VERSION}

RUN if ! getent group ${USER_GID} >/dev/null; then groupadd -g ${USER_GID} hostgrp; fi \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash claude \
 && mkdir -p /home/claude/.claude /home/claude/.m2 /home/claude/.npm \
 && mkdir -p /workspace \
 && chown -R ${USER_UID}:${USER_GID} /home/claude /workspace \
 && echo "claude ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/claude \
 && chmod 0440 /etc/sudoers.d/claude

COPY --chown=${USER_UID}:${USER_GID} claude-config.json /home/claude/.claude.json

RUN printf '[user]\n\tname = Claude\n\temail = claude@eighttrigrams.net\n[pull]\n\trebase = false\n[init]\n\tdefaultBranch = main\n' > /home/claude/.gitconfig \
 && chown ${USER_UID}:${USER_GID} /home/claude/.gitconfig

USER claude
ENV HOME=/home/claude

# Pre-warm the dependency caches so a locked-mode box (docker-compose.locked.yml)
# never reaches Clojars, Maven Central or the npm registry at runtime. None of
# them are in tinyproxy.filter -- they are broad exfil channels, which is the
# whole reason the box is locked -- so in locked mode a cold cache is a hard
# failure, not a slow first run.
#
# Each cache lands at a path where a runtime named volume mounts. Docker
# initializes an empty named volume from the image content at that path on first
# mount, so a scrubbed volume inherits everything baked here:
#   /home/claude/.m2                 -> m2_cache
#   /home/claude/.npm                -> npm_cache
#   /workspace/rhizome/node_modules  -> node_modules
#   /workspace/rhizome/.shadow-cljs  -> shadow_cache
# The bind mount over /workspace/rhizome hides the staged files themselves at
# runtime, which is fine: only the caches they produce need to survive.
#
# Inputs come from .build-stage, filled by run.sh before the build out of the
# rhizome checkout next door. The build context is this directory, so rhizome's
# deps.edn and the us-vs-them sibling checkout are otherwise unreachable from
# in here.
COPY --chown=${USER_UID}:${USER_GID} .build-stage/deps.edn            /workspace/rhizome/deps.edn
COPY --chown=${USER_UID}:${USER_GID} .build-stage/shadow-cljs.edn     /workspace/rhizome/shadow-cljs.edn
COPY --chown=${USER_UID}:${USER_GID} .build-stage/package.json        /workspace/rhizome/package.json
COPY --chown=${USER_UID}:${USER_GID} .build-stage/package-lock.json   /workspace/rhizome/package-lock.json
# rhizome's package.json takes the editor library as file:vendor/<packed>.tgz,
# which npm resolves against the filesystem rather than the registry -- so
# `npm ci` below dies on a missing file if this is not here. The bind mount
# brings the real vendor/ at runtime; this copy is only for the build.
COPY --chown=${USER_UID}:${USER_GID} .build-stage/vendor              /workspace/rhizome/vendor
# rhizome's deps.edn declares eighttrigrams/us-vs-them {:local/root
# "../us-vs-them"}, and tools.deps follows that during resolution, so this file
# has to be on disk before the one pointing at it. Only the deps.edn: `clj -P`
# resolves dependencies and never reads a :paths entry, and the source arrives
# at runtime on the read-only bind mount in docker-compose.yml.
COPY --chown=${USER_UID}:${USER_GID} .build-stage/us-vs-them-deps.edn /workspace/us-vs-them/deps.edn

# Several resolvers, because rhizome's runtime deps come from two places that
# do not know about each other:
#   `clj -P -M:dev`           one line per alias combination that is actually
#   `clj -P -M:test`          invoked at runtime -- start.sh uses :dev,
#   `clj -P -M:e2e`           run-tests.sh uses :test and -X:test, and
#   `clj -P -X:test`          playwright.config.ts's webServer uses :e2e ALONE.
#   `clj -P -M:dev:test:e2e`  Resolving only the combined set is not enough and
#                             was a real bug: tools.deps picks one version per
#                             conflict, so :dev:test:e2e together resolved
#                             transit-clj to 1.0.333 while :e2e alone wants
#                             1.0.329. The latter was never fetched, and in
#                             locked mode `make e2e` then died in the webServer
#                             with UnknownHostException on repo1.maven.org.
#                             Each combination must be prepared on its own.
#   `clj -P -T:build`         :build's own :deps (tools.build)
#   `npm ci`                  deterministic install from package-lock.json;
#                             does not consult the registry for a resolution
#                             the way `npm install` does
#   `shadow-cljs classpath`   shadow-cljs.edn carries its OWN :dependencies
#                             (reagent, cljs-ajax, ...) which it resolves into
#                             ~/.m2 itself -- `clj -P` above never sees them,
#                             and missing this is what would break `make start`
#                             and `make e2e` in locked mode.
# src/cljs and resources exist only so shadow-cljs's :source-paths resolve
# during the classpath computation; the real ones arrive on the bind mount.
#
# The .npm-installed sentinel is what stops entrypoint.sh running `npm install`
# on first entry -- in locked mode that call cannot reach the registry, and
# without the marker every fresh box would emit its failure warning.
RUN cd /workspace/rhizome \
 && mkdir -p src/cljs resources \
 && clj -P -M:dev \
 && clj -P -M:test \
 && clj -P -M:e2e \
 && clj -P -X:test \
 && clj -P -M:dev:test:e2e \
 && clj -P -T:build \
 && npm ci --silent --no-audit --no-fund \
 && npx shadow-cljs classpath \
 && touch node_modules/.npm-installed
