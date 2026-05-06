FROM clojure:temurin-21-tools-deps-bookworm-slim

ARG USER_UID=501
ARG USER_GID=20

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    jq \
    make \
    nodejs \
    npm \
    openssh-client \
    postgresql-client \
    sudo \
    chromium \
    libnss3 \
    libfreetype6 \
    libharfbuzz0b \
    ca-certificates \
    fonts-freefont-ttf \
    fonts-noto-color-emoji \
    lsof \
    procps \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sLO https://raw.githubusercontent.com/babashka/babashka/master/install \
 && chmod +x install \
 && ./install --dir /usr/local/bin --static \
 && rm install

ARG SQLITE_VEC_VERSION=0.1.9
RUN mkdir -p /usr/local/lib/sqlite-vec \
 && case "$(uname -m)" in \
      x86_64)  slug=linux-x86_64 ;; \
      aarch64) slug=linux-aarch64 ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/asg017/sqlite-vec/releases/download/v${SQLITE_VEC_VERSION}/sqlite-vec-${SQLITE_VEC_VERSION}-loadable-${slug}.tar.gz" \
    | tar -xz -C /tmp \
 && cp /tmp/vec0.so /usr/local/lib/sqlite-vec/vec0.so \
 && rm -f /tmp/vec0.so \
 && test -f /usr/local/lib/sqlite-vec/vec0.so
ENV SQLITE_VEC_PATH=/usr/local/lib/sqlite-vec/vec0

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV PATH="/opt/java/openjdk/bin:${PATH}"
RUN printf 'export JAVA_HOME=/opt/java/openjdk\nexport PATH=$JAVA_HOME/bin:$PATH\n' > /etc/profile.d/java.sh

RUN npm install -g @anthropic-ai/claude-code \
 && mv /usr/local/bin/claude /usr/local/bin/claude-bin \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude-bin --dangerously-skip-permissions "$@"\n' > /usr/local/bin/claude \
 && chmod +x /usr/local/bin/claude

RUN printf '#!/bin/sh\ncase "$1" in\n  push)\n    echo "git push is disabled inside the docker container." >&2\n    exit 1\n    ;;\n  commit|merge)\n    branch=$(/usr/bin/git rev-parse --abbrev-ref HEAD 2>/dev/null)\n    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then\n      echo "refusing to $1 on $branch from inside the container. switch to a feature branch first." >&2\n      exit 1\n    fi\n    ;;\nesac\nexec /usr/bin/git "$@"\n' > /usr/local/bin/git \
 && chmod +x /usr/local/bin/git

RUN if ! getent group ${USER_GID} >/dev/null; then groupadd -g ${USER_GID} hostgrp; fi \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash claude \
 && mkdir -p /home/claude/.claude /home/claude/.m2 /home/claude/.npm \
 && mkdir -p /workspace \
 && chown -R ${USER_UID}:${USER_GID} /home/claude /workspace

COPY --chown=${USER_UID}:${USER_GID} claude-config.json /home/claude/.claude.json

RUN printf '[user]\n\tname = Claude\n\temail = claude@eighttrigrams.net\n[init]\n\tdefaultBranch = main\n' > /home/claude/.gitconfig \
 && chown ${USER_UID}:${USER_GID} /home/claude/.gitconfig

# entrypoint.sh marks bind-mounted tracked files (e.g. .mcp.json) as
# skip-worktree on container start, so git status stays clean despite the
# mount-induced divergence from HEAD.
COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER claude
ENV HOME=/home/claude
WORKDIR /workspace/rhizome

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
