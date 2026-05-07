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
docker compose build claude
docker compose run --rm --service-ports "${EXTRA_VOLUMES[@]}" claude
