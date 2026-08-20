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

# ONE exit trap, doing both jobs. A second `trap ... EXIT` would silently
# REPLACE this one rather than add to it, and the casualty would be the
# skip-worktree clear above -- leaving the bit set and host-side npm diffs
# invisible. So anything else that needs to happen on the way out goes in here.
#
# Job two: take the compose project down. `docker compose run --rm` removes
# only the container it ran; the locked-mode sidecars (egress, ingress,
# ingress-shadow) carry `restart: unless-stopped` and nothing was taking them
# down, so they kept holding host PORT/SHADOW_PORT and the next `make yolo`
# failed to bind. --remove-orphans does NOT cover this: it removes containers
# whose service is absent from the currently loaded compose files, and in
# locked mode -- the default -- docker-compose.locked.yml is loaded, so those
# three are defined services rather than orphans. It only ever helped on a
# locked-then-open transition.
#
# `down` rather than stopping the three by name: it also drops the networks,
# and it stays correct if a sidecar is ever added. The cost is that the ollama
# sidecar stops too and has to restart next run -- a few seconds, and the model
# is in an external volume that `down` does not touch, so nothing is re-pulled.
CLEANED_UP=0
cleanup() {
  [ "$CLEANED_UP" = 1 ] && return 0
  CLEANED_UP=1
  [ "$PKG_LOCK_FLAG_SET" = 1 ] && \
    git -C "$RHIZOME_DIR" update-index --no-skip-worktree package-lock.json 2>/dev/null
  docker compose down --remove-orphans >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
# ctrl+c / SIGTERM: run the same cleanup, then leave with the conventional
# status. Without these the shell can die on the signal without the EXIT trap
# ever running, which is how ctrl+c used to leave sidecars behind.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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
# --remove-orphans: clears containers left by a *different* mode -- the
# locked-mode sidecars are orphans when this runs open. What takes them down in
# locked mode is the exit trap above, not this flag.
# --name: a fixed, memorable container name instead of compose's
# `<project>-claude-run-<random hex>`. Two knock-ons, both wanted: the
# blocked-port message in rhizome's detect-ports.sh tells you to
# `docker stop <name>`, which is now something a human can type; and a second
# concurrent `make yolo` fails immediately with "container name is already in
# use" rather than quietly starting a second box. `--rm` still removes the
# container on exit, so the name is free again for the next run.
#
# The name is the hostname, deliberately not the compose project. The project
# is already `rhizome-yolo` (it is the directory name), and giving the container
# that same string makes Docker Desktop show two rows both reading
# "rhizome-yolo" -- the stack and the container inside it -- indistinguishable
# at a glance. BOX_NAME comes from the Makefile so the yolo-clean guard tests
# the same name; the default keeps this script runnable on its own.
docker compose run --rm --service-ports --use-aliases --remove-orphans \
  --name "${BOX_NAME:-yolo-box}" \
  "${EXTRA_VOLUMES[@]}" claude
