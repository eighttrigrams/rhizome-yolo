#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/token"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "Token file not found at: $TOKEN_FILE"
  echo "Run 'claude setup-token' on the host and save the the token it prints line to that file."
  exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")

cd "$SCRIPT_DIR"

# Default: locked egress. Only hosts matching tinyproxy.filter (just
# api.anthropic.com) are reachable, and the internal `locked` network leaves no
# default gateway for anything that ignores HTTP(S)_PROXY -- that second gate is
# the one that actually holds. Opt out with `./run.sh +internet`, or
# `make yolo INTERNET=1`. Mirrors ../../docker/run.sh for the plurama box.
#
# Appended to the COMPOSE_FILE the Makefile exports, so these two land after the
# per-machine override that comes last in it. The fallback covers running this
# script directly rather than through `make yolo`.
BUILD_SERVICES=(claude)
if [ "${1:-}" != "+internet" ]; then
  export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:compose.ports.yml}:docker-compose.locked.yml:compose.ports.locked.yml"
  # `docker compose run` builds no sidecars of its own, so the tinyproxy image
  # has to be named here or the first locked run dies on a missing image.
  BUILD_SERVICES+=(egress)
  echo "Egress: LOCKED (only tinyproxy.filter hosts reachable)."
  echo "        './run.sh +internet' or 'make yolo INTERNET=1' for full internet."
else
  echo "Egress: OPEN (full internet)."
fi

# Seed a container-private package-lock.json the first time, so npm install
# inside the container doesn't rewrite the host's lockfile through the
# rhizome bind-mount. Subsequent runs reuse whatever the container wrote.
if [ ! -f package-lock.json ] && [ -f ../package-lock.json ]; then
  cp ../package-lock.json package-lock.json
fi

# The compose file bind-mounts ./package-lock.json over the host's
# rhizome/package-lock.json. While the container runs, that file is pinned by
# the kernel, so host-side git operations (`checkout`, `rebase`, `pull`)
# fail with "unable to unlink old 'package-lock.json': Device or resource
# busy". Set skip-worktree for the duration of the run so git skips it,
# then clear the bit on exit so host-side `npm install` diffs surface again.
PKG_LOCK_FLAG_SET=0
if git -C .. update-index --skip-worktree package-lock.json 2>/dev/null; then
  PKG_LOCK_FLAG_SET=1
fi
trap '[ "$PKG_LOCK_FLAG_SET" = 1 ] && git -C "$SCRIPT_DIR/.." update-index --no-skip-worktree package-lock.json 2>/dev/null || true' EXIT

EXTRA_VOLUMES=()
PARENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
for sibling in rhizome-books claude-stuff; do
  host_path="$PARENT_DIR/$sibling"
  if [ -d "$host_path" ]; then
    echo "Mounting sibling $sibling from $host_path"
    EXTRA_VOLUMES+=(-v "$host_path:/workspace/$sibling:rw")
  fi
done

export WITH_VEC="${WITH_VEC:-0}"

# Fill the build context for the Dockerfile's dependency pre-warm, which is what
# lets locked mode run without Clojars / Maven Central / the npm registry. The
# build context is this directory, so the checkout's deps.edn / shadow-cljs.edn /
# package.json and the us-vs-them sibling are unreachable from the Dockerfile
# otherwise. Refreshed every run so a dependency bump reaches the next build.
STAGE_DIR="$SCRIPT_DIR/.build-stage"
mkdir -p "$STAGE_DIR"
cp ../deps.edn          "$STAGE_DIR/deps.edn"
cp ../shadow-cljs.edn   "$STAGE_DIR/shadow-cljs.edn"
cp ../package.json      "$STAGE_DIR/package.json"
# The checkout's lockfile, not the container-private package-lock.json seeded
# above: `npm ci` aborts unless the lockfile agrees with package.json, and that
# pair is the one guaranteed to.
cp ../package-lock.json "$STAGE_DIR/package-lock.json"
# Only the deps.edn -- see the COPY comment in Dockerfile for why the source
# isn't needed at build time.
if [ ! -f ../../us-vs-them/deps.edn ]; then
  echo "run.sh: no ../../us-vs-them/deps.edn." >&2
  echo "  rhizome's deps.edn names it as a :local/root sibling, so the image" >&2
  echo "  cannot resolve deps without it. See README, 'Getting started'." >&2
  exit 1
fi
cp ../../us-vs-them/deps.edn "$STAGE_DIR/us-vs-them-deps.edn"

# A failed build must not fall through to `run`, which would silently start
# the previous image and make the failure look like success.
docker compose build "${BUILD_SERVICES[@]}" || exit $?
# --use-aliases: publishes the service's network alias (`claude`) so the socat
# ingress sidecars can resolve and forward to it in locked mode. Harmless open.
# --remove-orphans: the locked-mode sidecars carry `restart: unless-stopped` and
# survive `--rm`, so without this they keep holding the host ports and the next
# run fails to bind.
docker compose run --rm --service-ports --use-aliases --remove-orphans \
  "${EXTRA_VOLUMES[@]}" claude
