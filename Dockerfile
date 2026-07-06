# Multi-stage build: `base` carries the common rhizome dev toolchain; `box` is
# a plain dev shell (root) and `yolo` adds the unprivileged `claude` user plus
# the Playwright/browser stack and the claude-code CLI. Pick a stage via
# `target:` in docker-compose.yml.
FROM clojure:temurin-21-tools-deps-bookworm-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    imagemagick \
    jq \
    make \
    nodejs \
    npm \
    sqlite3 \
    ca-certificates \
    lsof \
    procps \
    socat \
    zstd \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sLO https://raw.githubusercontent.com/babashka/babashka/master/install \
 && chmod +x install \
 && ./install --dir /usr/local/bin --static \
 && rm install

ARG SQLITE_VEC_VERSION=0.1.9
ARG WITH_VEC=0
RUN if [ "$WITH_VEC" = "1" ]; then \
      mkdir -p /usr/local/lib/sqlite-vec \
   && case "$(uname -m)" in \
        x86_64)  slug=linux-x86_64 ;; \
        aarch64) slug=linux-aarch64 ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
      esac \
   && curl -fsSL "https://github.com/asg017/sqlite-vec/releases/download/v${SQLITE_VEC_VERSION}/sqlite-vec-${SQLITE_VEC_VERSION}-loadable-${slug}.tar.gz" \
      | tar -xz -C /tmp \
   && cp /tmp/vec0.so /usr/local/lib/sqlite-vec/vec0.so \
   && rm -f /tmp/vec0.so \
   && test -f /usr/local/lib/sqlite-vec/vec0.so; \
    else \
      echo "Skipping sqlite-vec install (WITH_VEC=0)"; \
    fi

# Flag the entrypoint reads to decide whether to wait for the Ollama sidecar
# and pull the embedding model on first run. Set in lockstep with the
# sqlite-vec install above so semsearch dependencies stay together.
RUN if [ "$WITH_VEC" = "1" ]; then echo "1" > /etc/rhizome-use-ollama; else echo "0" > /etc/rhizome-use-ollama; fi

# config.edn's :semsearch entries use aero #or [#env ...] so the same file
# works on host and in the container. Inside the container:
#   * the sqlite-vec .so lives at /usr/local/lib/sqlite-vec/vec0 (see the
#     WITH_VEC RUN block above)
#   * the ollama sidecar is reached via a socat bridge on 127.0.0.1:11437
#     (entrypoint.sh), kept off :11434 so a host-side ollama exposed into
#     this container's network namespace can't shadow the sidecar
# Set unconditionally -- harmless when :semsearch isn't in config.edn, and
# means we don't carry a second copy of the WITH_VEC conditional here.
ENV VEC_PATH=/usr/local/lib/sqlite-vec/vec0
ENV VEC_URL=http://127.0.0.1:11437

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Block `git push` from inside the container (inherited by both box and yolo).
# Committing/merging (including on main) is allowed -- in-box commits are
# traceable via the baked-in Claude git identity.
RUN printf '#!/bin/sh\ncase "$1" in\n  push)\n    echo "git push is disabled inside the docker container." >&2\n    exit 1\n    ;;\nesac\nexec /usr/bin/git "$@"\n' > /usr/local/bin/git \
 && chmod +x /usr/local/bin/git

WORKDIR /workspace/rhizome
# Rhizome dev ports per ../README.md: PORT=3140 (JVM), SHADOW_PORT=9804 (shadow-cljs).
# EXPOSE is documentation only; actual publishing is via compose --service-ports.
EXPOSE 3140 9804
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


# ---------------------------------------------------------------------------
# box: plain dev shell, runs as root, no browser stack, no claude CLI.
# `make e2e` from inside `box` will fail by design with a directed message
# (see scripts/e2e.sh) -- e2e lives in the yolo image (or on the host).
# ---------------------------------------------------------------------------
FROM base AS box
# Bake in the Claude git identity so in-box commits (as root) are attributed
# to Claude <claude@eighttrigrams.net>, matching ../docker. pull.rebase=false
# enforces the merge-not-rebase policy.
RUN printf '[user]\n\tname = Claude\n\temail = claude@eighttrigrams.net\n[pull]\n\trebase = false\n[init]\n\tdefaultBranch = main\n' > /root/.gitconfig
CMD ["bash"]


# ---------------------------------------------------------------------------
# yolo: isolated environment for the claude-code CLI. Adds Playwright/Chromium,
# postgres + ssh + jq for the agent's tooling, and a non-root `claude` user
# whose UID/GID are aligned with the host so bind mounts stay writeable.
# ---------------------------------------------------------------------------
FROM base AS yolo

ARG USER_UID=501
ARG USER_GID=20

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
ARG PLAYWRIGHT_VERSION=1.58.2
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN mkdir -p /opt/ms-playwright /tmp/pwsetup && cd /tmp/pwsetup \
 && npm init -y >/dev/null \
 && npm install playwright-core@${PLAYWRIGHT_VERSION} >/dev/null \
 && npx playwright-core install chromium-headless-shell \
 && rm -rf /tmp/pwsetup \
 && ln -s "$(find /opt/ms-playwright -type f -name headless_shell | head -1)" /usr/local/bin/pw-chromium \
 && chmod -R a+rX /opt/ms-playwright \
 && /usr/local/bin/pw-chromium --version

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/local/bin/pw-chromium \
    PATH="/opt/java/openjdk/bin:${PATH}"

# Java profile script so login shells (and the claude-code wrapper) see JAVA_HOME.
RUN printf 'export JAVA_HOME=/opt/java/openjdk\nexport PATH=$JAVA_HOME/bin:$PATH\n' > /etc/profile.d/java.sh

# Always pass --dangerously-skip-permissions when invoked inside the sandbox.
RUN npm install -g @anthropic-ai/claude-code \
 && mv /usr/local/bin/claude /usr/local/bin/claude-bin \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude-bin --dangerously-skip-permissions "$@"\n' > /usr/local/bin/claude \
 && chmod +x /usr/local/bin/claude

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
