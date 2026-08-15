#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/token"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "Token file not found at: $TOKEN_FILE"
  echo "Run 'claude setup-token' on the host and save the token line it prints to that file."
  exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")

cd "$SCRIPT_DIR"

# The rhizome checkout this box works on. Everything host-side that this script
# reads -- deps.edn, the lockfile, the vendored editor, the base image's build
# context -- comes from there, and compose bind-mounts it at /workspace/rhizome.
# `make yolo` exports this; the fallback covers running this script directly.
RHIZOME_DIR="${RHIZOME_DIR:-../rhizome}"
if [ ! -d "$RHIZOME_DIR/docker" ]; then
  echo "run.sh: no rhizome checkout at $RHIZOME_DIR." >&2
  echo "  This repo is only the sandbox; the code it boxes lives next door." >&2
  echo "  Clone rhizome as a sibling, or set RHIZOME_DIR=/path/to/rhizome." >&2
  echo "  See README, 'Layout'." >&2
  exit 1
fi
RHIZOME_DIR="$(cd "$RHIZOME_DIR" && pwd)"
export RHIZOME_DIR

# Default: locked egress. Only hosts matching tinyproxy.filter (just
# api.anthropic.com) are reachable, and the internal `locked` network leaves no
# default gateway for anything that ignores HTTP(S)_PROXY -- that second gate is
# the one that actually holds. Opt out with `./run.sh +internet`, or
# `make yolo INTERNET=1`. Mirrors ../docker/run.sh for the plurama box.
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
# inside the container doesn't rewrite rhizome's lockfile through the
# bind-mount. Subsequent runs reuse whatever the container wrote.
if [ ! -f package-lock.json ] && [ -f "$RHIZOME_DIR/package-lock.json" ]; then
  cp "$RHIZOME_DIR/package-lock.json" package-lock.json
fi

# The compose file bind-mounts ./package-lock.json over rhizome's
# package-lock.json. While the container runs, that file is pinned by the
# kernel, so host-side git operations (`checkout`, `rebase`, `pull`) in rhizome
# fail with "unable to unlink old 'package-lock.json': Device or resource
# busy". Set skip-worktree for the duration of the run so git skips it, then
# clear the bit on exit so host-side `npm install` diffs surface again.
PKG_LOCK_FLAG_SET=0
if git -C "$RHIZOME_DIR" update-index --skip-worktree package-lock.json 2>/dev/null; then
  PKG_LOCK_FLAG_SET=1
fi
trap '[ "$PKG_LOCK_FLAG_SET" = 1 ] && git -C "$RHIZOME_DIR" update-index --no-skip-worktree package-lock.json 2>/dev/null || true' EXIT

EXTRA_VOLUMES=()
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
for sibling in rhizome-books claude-stuff; do
  host_path="$PARENT_DIR/$sibling"
  if [ -d "$host_path" ]; then
    echo "Mounting sibling $sibling from $host_path"
    EXTRA_VOLUMES+=(-v "$host_path:/workspace/$sibling:rw")
  fi
done

export WITH_VEC="${WITH_VEC:-0}"

# claude_home and ollama_models are declared `external: true` in
# docker-compose.yml so they are per machine rather than per compose project
# (see the volumes block there for why). External disables compose's
# auto-creation, so they have to exist before the box comes up. `docker volume
# create` is idempotent -- a no-op when they already do, which is how the
# volumes the `rhizome` project already had under these names are adopted
# rather than replaced.
docker volume create rhizome_claude_home >/dev/null
if [ "$WITH_VEC" = "1" ]; then
  docker volume create rhizome_ollama_models >/dev/null
fi

# Fill the build context for the Dockerfile's dependency pre-warm, which is what
# lets locked mode run without Clojars / Maven Central / the npm registry. The
# build context is this directory, so rhizome's deps.edn / shadow-cljs.edn /
# package.json and the us-vs-them sibling are unreachable from the Dockerfile
# otherwise. Refreshed every run so a dependency bump reaches the next build.
STAGE_DIR="$SCRIPT_DIR/.build-stage"
mkdir -p "$STAGE_DIR"
cp "$RHIZOME_DIR/deps.edn"          "$STAGE_DIR/deps.edn"
cp "$RHIZOME_DIR/shadow-cljs.edn"   "$STAGE_DIR/shadow-cljs.edn"
cp "$RHIZOME_DIR/package.json"      "$STAGE_DIR/package.json"
# Rhizome's lockfile, not the container-private package-lock.json seeded above:
# `npm ci` aborts unless the lockfile agrees with package.json, and that pair is
# the one guaranteed to.
cp "$RHIZOME_DIR/package-lock.json" "$STAGE_DIR/package-lock.json"
# The editor library, packed. rhizome's package.json depends on it as
# file:vendor/*.tgz -- a path npm resolves on disk, not from the registry -- so
# `npm ci` in the image fails on a missing file without it, in locked and open
# mode alike. Re-packed by the suite's vendor-editor.sh, whose --check also
# asserts this copy exists.
rm -rf "$STAGE_DIR/vendor"
cp -R "$RHIZOME_DIR/vendor"         "$STAGE_DIR/vendor"
# Only the deps.edn -- see the COPY comment in Dockerfile for why the source
# isn't needed at build time.
if [ ! -f "$RHIZOME_DIR/../us-vs-them/deps.edn" ]; then
  echo "run.sh: no us-vs-them checkout beside rhizome." >&2
  echo "  rhizome's deps.edn names it as a :local/root sibling, so the image" >&2
  echo "  cannot resolve deps without it. See README, 'Layout'." >&2
  exit 1
fi
cp "$RHIZOME_DIR/../us-vs-them/deps.edn" "$STAGE_DIR/us-vs-them-deps.edn"

# The shared `base` stage lives in rhizome's Dockerfile and cannot be reached
# with `FROM base` across files, so build it here as a tagged image first.
# WITH_VEC is a build arg to that stage -- it decides whether sqlite-vec is
# installed and whether entrypoint.sh brings up the ollama bridge -- so the tag
# has to encode it. Without that, a novec base built for an earlier run would be
# silently reused for a WITH_VEC=1 one. After the first build of each tag this
# is a cache hit and costs nothing.
BASE_TAG="$([ "$WITH_VEC" = "1" ] && echo vec || echo novec)"
export BASE_TAG
echo "Building base image rhizome-base:$BASE_TAG from $RHIZOME_DIR/docker ..."
docker build --target base \
  --build-arg WITH_VEC="$WITH_VEC" \
  -t "rhizome-base:$BASE_TAG" \
  "$RHIZOME_DIR/docker" || exit $?

# A failed build must not fall through to `run`, which would silently start
# the previous image and make the failure look like success.
docker compose build "${BUILD_SERVICES[@]}" || exit $?
# --use-aliases: publishes the service's network alias (`claude`) so the socat
# ingress sidecars can resolve and forward to it in locked mode. Harmless open.
# --remove-orphans: the locked-mode sidecars carry `restart: unless-stopped` and
# survive `--rm`, so without this they keep holding the host ports and the next
# run fails to bind. Safe only because this is its own compose project -- see
# the header of docker-compose.yml.
docker compose run --rm --service-ports --use-aliases --remove-orphans \
  "${EXTRA_VOLUMES[@]}" claude
