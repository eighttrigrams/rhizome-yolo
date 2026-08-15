# rhizome-yolo: the agent sandbox for the rhizome checkout next door.
#
# One target, `yolo`. Everything else a developer does -- start, stop, test,
# e2e, onboard -- is rhizome's Makefile, run from inside the box.

# The rhizome checkout this box works on. Sibling by default; override for a
# second checkout (make yolo RHIZOME_DIR=../rhizome.alt).
RHIZOME_DIR ?= ../rhizome

ifeq (,$(wildcard $(RHIZOME_DIR)/scripts/detect-ports.sh))
$(error No rhizome checkout at $(RHIZOME_DIR). This repo is only the sandbox; \
the code it boxes lives next door. Clone rhizome as a sibling, or pass \
RHIZOME_DIR=/path/to/rhizome. See README, 'Layout')
endif

# Ports: env wins (`?=` skips the $(shell ...) if PORT/SHADOW_PORT are already
# exported -- by direnv, the user's shell, CI, etc.). Otherwise they are
# resolved out of the rhizome checkout, by rhizome's own detect-ports.sh
# reading its config.edn / shadow-cljs.edn. That script stays over there on
# purpose: it is the source of truth for both sides, and duplicating it here
# would let the box and the host disagree about which port the app is on.
PORT        ?= $(shell $(RHIZOME_DIR)/scripts/detect-ports.sh PORT)
SHADOW_PORT ?= $(shell $(RHIZOME_DIR)/scripts/detect-ports.sh SHADOW_PORT)

.PHONY: yolo yolo-clean

# When WITH_VEC=1, also activate the `vec` compose profile so the Ollama
# sidecar starts. Otherwise it stays absent and runs that don't need semsearch
# never pay the pull cost. WITH_VEC also picks the base image tag -- run.sh
# derives BASE_TAG from it.
COMPOSE_VEC = $(if $(filter 1,$(WITH_VEC)),COMPOSE_PROFILES=vec,)

# Always layer docker-compose.yml with the generated compose.ports.yml so the
# host bindings come from rhizome's config.edn / shadow-cljs.edn rather than
# YAML fallbacks. COMPOSE_FILE uses ':' as separator (compose convention).
#
# docker-compose.override.yml is the gitignored, per-machine layer (this
# checkout's owner mounts an in-box CLAUDE.md and a credential proxy through
# it). Compose only auto-loads an override file when COMPOSE_FILE is unset --
# and we always set it -- so it has to be named here, last, to win. Named only
# when present: a COMPOSE_FILE entry that does not exist is a hard error from
# compose, and this file is absent in every clone but its owner's. $(wildcard)
# reads a dangling symlink as absent too, which is what we want.
COMPOSE_OVERRIDE = $(if $(wildcard docker-compose.override.yml),:docker-compose.override.yml,)
COMPOSE_FILES = COMPOSE_FILE=docker-compose.yml:compose.ports.yml$(COMPOSE_OVERRIDE)

# Compose project name is derived from this checkout's directory name, so this
# project stays distinct from the `rhizome` project that `make box` runs in --
# which matters, because run.sh passes --remove-orphans. Compose project names
# must match [a-z0-9][a-z0-9_-]* -- lowercase the basename and replace `.` with
# `-` (covers names like "rhizome-yolo.alt").
COMPOSE_PROJECT_NAME := $(subst .,-,$(shell echo $(notdir $(CURDIR)) | tr '[:upper:]' '[:lower:]'))

# Same PORT/SHADOW_PORT also flow into the container as env vars; aero in
# rhizome's config.clj and shadow-cljs honor them via #env so the JVM/shadow
# bind to the host-bound port.
COMPOSE_ENV = PORT=$(PORT) SHADOW_PORT=$(SHADOW_PORT) WITH_VEC=$(WITH_VEC) RHIZOME_DIR=$(RHIZOME_DIR) COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) $(COMPOSE_VEC) $(COMPOSE_FILES)

# The box runs with locked egress by default -- run.sh layers in
# docker-compose.locked.yml, and only tinyproxy.filter's hosts get out.
# INTERNET=1 is the escape hatch, and maps onto the `+internet` argument
# run.sh already takes.
YOLO_INTERNET = $(if $(filter 1,$(INTERNET)),+internet,)

# The port check, the ports overlay and run.sh are chained in a single shell so
# a refusal (exit 0 via ||) actually skips the rest of the recipe. Make runs
# each recipe line in its own shell, so a multi-line form would exit 0 on the
# guard and then merrily build/run docker anyway.
yolo:
	@$(RHIZOME_DIR)/scripts/detect-ports.sh check PORT SHADOW_PORT || exit 0; \
	./write-compose-ports.sh $(PORT) $(SHADOW_PORT) && \
	$(COMPOSE_ENV) ./run.sh $(YOLO_INTERNET)

# Drop the dependency caches so the next `make yolo` re-seeds them from the
# image. Needed after anything that changes what the Dockerfile pre-warms --
# a dependency bump in rhizome's deps.edn, package.json or shadow-cljs.edn,
# or a new resolver line in the pre-warm itself.
#
# Rebuilding alone is NOT enough, and the failure is nasty: Docker copies image
# content into a named volume only when that volume is EMPTY, so an existing
# box keeps serving the stale cache while the build reports success. In locked
# mode the missing artifact then surfaces at runtime as a DNS error against
# repo1.maven.org, nowhere near the change that caused it.
#
# Deliberately NOT touched: the ollama model volume (shared with `make box`,
# ~900 MB to re-pull, and never seeded from this image anyway) and claude_home
# (the agent's own config and session history).
CACHE_VOLUMES = m2_cache node_modules npm_cache shadow_cache cpcache

yolo-clean:
	@if [ -n "$$(docker ps -q --filter name=^$(COMPOSE_PROJECT_NAME)$$)" ]; then \
	  echo "The box is still running -- exit it first, or the volumes are in use." >&2; \
	  exit 1; \
	fi; \
	for v in $(CACHE_VOLUMES); do \
	  docker volume rm "$(COMPOSE_PROJECT_NAME)_$$v" >/dev/null 2>&1 \
	    && echo "removed $(COMPOSE_PROJECT_NAME)_$$v" \
	    || echo "skipped $(COMPOSE_PROJECT_NAME)_$$v (absent or in use)"; \
	done; \
	echo "Next 'make yolo' re-seeds these from the image."
