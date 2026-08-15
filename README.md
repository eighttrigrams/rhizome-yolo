## Docker - Claude YOLO

Sandboxed Claude (using Docker). Run

```bash
make yolo
claude@yolo-box:/workspace/rhizome$ make onboard # if haven't done already
claude@yolo-box:/workspace/rhizome$ claude # has playwright MCP, can start app etc.
```

Its egress is locked. The box sits on an internal network with no default
gateway, and the only route out is a tinyproxy sidecar forwarding to the hosts
listed in `tinyproxy.filter` — `api.anthropic.com` and nothing else. Its
dependencies are baked into the image at build time, so no run needs Clojars,
Maven Central or the npm registry. See "Locked egress" below to allow another
host.

The escape hatch, when a run genuinely needs the network (bumping dependencies,
say):

```bash
make yolo INTERNET=1
```

Rhizome's own `make box` is unaffected either way — it is the plain root dev
shell, not an agent surface, and stays on the default bridge. It also needs
nothing from this repo.

## What this repo is

Only the cage. It holds no application code — the code it boxes lives in the
rhizome checkout next door, which is bind-mounted into the container at
`/workspace/rhizome`. Nothing in here is ever mounted into the box.

Rhizome itself needs none of this. Reach for this repo only when you want an
*agent* driving that checkout rather than a person.

## Layout

Three sibling checkouts:

```
some-parent/
  rhizome/        the app
  rhizome-yolo/   this repo
  us-vs-them/     github.com/eighttrigrams/us-vs-them — rhizome's deps.edn
                  names it {:local/root "../us-vs-them"}
```

`../rhizome` is the default; point elsewhere with `make yolo
RHIZOME_DIR=../rhizome.alt`. `us-vs-them` is expected beside this repo either
way.

## The token

One-time, on the host, before the first `make yolo`:

```bash
claude setup-token          # save the token line it prints to ./token
```

`token` is gitignored, and is the only secret this repo touches.

Everything else you do inside the box is rhizome's own Makefile — `make
onboard`, `make start`, `make test`, `make e2e`. This repo has exactly one
target.

The app comes up on the host at `http://localhost:3140`, or wherever rhizome's
`PORT` resolves to — the ports are read straight out of that checkout by its
`scripts/detect-ports.sh`, so both sides always agree.

## The optional per-machine layer

Nothing here is needed to run this box, and a fresh clone has none of it. It is
the hook for whatever a particular machine wants to add.

If a file named exactly `docker-compose.override.yml` exists **in this
directory**, the Makefile appends it to `COMPOSE_FILE`, last, so it wins.
Compose only auto-loads an override when `COMPOSE_FILE` is unset — and we
always set it — so it has to be named explicitly. It is named only when
present: an entry in `COMPOSE_FILE` that does not exist is a hard error from
compose, not a skipped file. `$(wildcard)` treats a *dangling symlink* as
absent too, which is what you want if you symlink it out to a dotfiles repo.

It is gitignored. Keep secrets out of it anyway — it is the kind of file people
sync.

Two traps, both of which fail **silently**:

- **A bind source that does not exist becomes an empty directory.** Docker
  creates it rather than erroring, at build time and at run time. So an
  override that mounts a host script to `/usr/local/bin/plurama-cli` with a
  wrong absolute path does not fail — it leaves a *directory* at that path, and
  the command simply is not there. Same for a config file: you get an empty dir
  where the file should be. If something mounted this way seems absent in the
  box, check whether it arrived as a directory.
- **`./CLAUDE.md` in an override resolves against this directory**, not against
  the override's own location on disk. Compose resolves relative paths against
  the project directory. So if the override mounts
  `./CLAUDE.md:/workspace/CLAUDE.md:ro` — the usual way to give the in-box doer
  its project instructions — then `CLAUDE.md` has to sit *here*, beside the
  override, however the override itself got here. Miss it and, per the trap
  above, `/workspace/CLAUDE.md` is an empty directory and the agent starts with
  no project instructions at all, with nothing in the logs to say so.

An override may also reference host-side helper scripts by absolute path —
tooling its owner maintains outside both this repo and rhizome. Nothing here
points at those, by design, and nothing here can check them; the
empty-directory rule above is the whole failure mode to watch for.

## What's inside the container

The image is built in two pieces. The shared half is the `base` stage of
`../rhizome/docker/Dockerfile` — JDK 21 + `clj`, Node 22 + npm, `bb`, `make`,
`git`, `sqlite3`, `jq`, `socat`, `lsof`, `imagemagick`, plus the optional
sqlite-vec install and the entrypoint. `FROM base` cannot cross files, so
`run.sh` builds that stage out of the rhizome checkout and tags it
`rhizome-base:vec` / `rhizome-base:novec` (the tag has to encode `WITH_VEC`,
which is a build arg to that stage), and this repo's `Dockerfile` starts from
the tag.

On top of it, the agent surface: Playwright's Chromium, the `claude` CLI
(wrapped to always pass `--dangerously-skip-permissions`), `@playwright/mcp`,
`postgresql-client`, `openssh-client`, a `git` wrapper that refuses `push`, and
a non-root `claude` user whose UID/GID match the host's so bind mounts stay
writeable.

## Locked egress

Two gates, not one. `HTTP(S)_PROXY` routes well-behaved tools through tinyproxy,
which enforces the whitelist; anything that ignores those vars finds no default
gateway at all, because the box sits on an `internal: true` network. The second
gate is the one that actually holds.

Sidecars, brought up by `depends_on` in `docker-compose.locked.yml`:

- **egress** (tinyproxy) — the only route out. Forwards solely to hosts matching
  `tinyproxy.filter`, configured by `tinyproxy.conf`, built from
  `tinyproxy.Dockerfile`. Reached via `HTTPS_PROXY=http://egress:8888`.
- **ingress**, **ingress-shadow** (socat) — host → container forwarders for the
  JVM and shadow-cljs ports. Needed because Docker silently drops published
  ports on a container attached only to an `internal: true` network. Their
  commands come from the generated `compose.ports.locked.yml`.

All three carry `restart: unless-stopped`, and `docker compose run --rm` removes
only the container it ran — so `run.sh` takes the project down in its exit trap.
Without that they keep holding the host ports and the next `make yolo` cannot
bind.

Allow another host by adding a line to `tinyproxy.filter` and rebuilding the
egress image:

```bash
docker compose -f docker-compose.yml -f docker-compose.locked.yml build egress
```

Prefer that over widening it to a package registry: the image resolves `clj`,
`npm` and shadow-cljs dependencies at build time (see the pre-warm block in
`Dockerfile`) precisely so the registries can stay out of the filter, where they
would be broad exfiltration channels.

Which makes a dependency bump a deliberate act. Rebuilding is not enough on its
own: Docker seeds a named volume from the image only when the volume is *empty*,
so existing `m2_cache` / `node_modules` / `shadow_cache` volumes keep whatever
they already hold. Either take the bump in open mode:

```bash
make yolo INTERNET=1     # resolve the new deps once, into the live volumes
```

or scrub the volumes so the next `make yolo` re-seeds them from a fresh image:

```bash
docker volume rm rhizome-yolo_m2_cache rhizome-yolo_node_modules rhizome-yolo_shadow_cache
```

Verify from inside the box:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/  # reaches proxy
curl --max-time 5 -sS https://example.com/                            # blocked
# Not merely unset-proxy-able: the internal network has no gateway either.
env -u HTTPS_PROXY -u HTTP_PROXY bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443'
```

## Vector search

Off by default. `make yolo WITH_VEC=1` builds the base stage with `sqlite-vec`
and brings up an Ollama sidecar holding `qwen3-embedding:0.6b`, so semantic
search works inside the container with no host-side install.

The model is the one part that lives in a volume rather than the image, and the
`ollama` sidecar joins `locked` and **not** `outside` — so it cannot fetch one
at runtime. Dual-homing it would let anything in the box ask it to
`POST /api/pull` a name like `some.host/ns/model`, an unauthenticated way out
past the filter. Seed it once from open mode instead:

```bash
make yolo WITH_VEC=1 INTERNET=1    # pulls qwen3-embedding:0.6b into ollama_models
make yolo WITH_VEC=1               # locked from here on; model served offline
```

On a cold `ollama_models` volume in locked mode, the entrypoint logs
`model pull failed` and carries on with semsearch unavailable.

## Volumes

Most of what the box keeps is namespaced per compose project, so a second
checkout of this repo gets its own. Two are deliberately per *machine*, under
fixed names, because re-deriving them costs something real:

- `rhizome_ollama_models` — the embedding model, ~640 MB. Shared with rhizome's
  own `make box WITH_VEC=1`, which declares it the same way.
- `rhizome_claude_home` — the agent's `/home/claude/.claude`: its sessions and
  history, which is what `claude --resume` reads.

Both are `external: true`, so `run.sh` runs `docker volume create` for them
first (idempotent).

### `make yolo-clean` after anything that changes the pre-warm

The cache volumes — `m2_cache`, `node_modules`, `npm_cache`, `shadow_cache`,
`cpcache` — are filled from the image, by the dependency pre-warm at the end of
the Dockerfile. That is what lets locked mode run without ever reaching Clojars,
Maven Central or the npm registry.

**Rebuilding the image does not refresh them.** Docker copies image content into
a named volume only when that volume is *empty*, so a box that already has these
volumes keeps serving the old cache while the build reports success. Bump a
dependency in rhizome's `deps.edn`, `package.json` or `shadow-cljs.edn`, rebuild,
and the box will still be missing it — surfacing much later as a runtime
`UnknownHostException: repo1.maven.org`, nowhere near the change that caused it.

So after any such bump:

```bash
make yolo-clean     # exit the box first; it refuses while the box is running
make yolo
```

It leaves `rhizome_ollama_models` and `rhizome_claude_home` alone — the two
above, which are not seeded from this image and are expensive or irreplaceable.

This is also the only honest way to test the pre-warm. A long-lived cache
accumulates artifacts from every run that ever had `INTERNET=1`, so a gap in it
stays invisible on a machine that has been running the box for a while, and
appears on someone else's first clone. `make yolo-clean` followed by a locked
`make e2e` is the check that actually means something.
