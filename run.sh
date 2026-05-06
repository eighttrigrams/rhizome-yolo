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

EXTRA_VOLUMES=()
PARENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
for sibling in rhizome-books claude-stuff; do
  host_path="$PARENT_DIR/$sibling"
  if [ -d "$host_path" ]; then
    echo "Mounting sibling $sibling from $host_path"
    EXTRA_VOLUMES+=(-v "$host_path:/workspace/$sibling:rw")
  fi
done

docker compose run --rm --service-ports "${EXTRA_VOLUMES[@]}" claude
