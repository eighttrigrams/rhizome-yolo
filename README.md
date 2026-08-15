# docker-rhizome

Run Rhizome dev (and Claude Code) inside an isolated container.

## What's inside the container

Two images are built from one `Dockerfile`, sharing a `base` stage and picked
via `target:` in `docker-compose.yml`:

- **`box`** (`make box`) — the plain dev shell, as root. `base` and nothing on
  top of it: JDK 21 + `clj`, Node 22 + npm, `bb`, `make`, `git`, `sqlite3`,
  `jq`, `socat`, `lsof`, `imagemagick`. `make e2e` from in here fails by design
  (see `scripts/e2e.sh`) — it needs a browser, which lives in the other image.
- **`yolo`** (`make yolo`) — the agent surface. Adds Playwright's Chromium, the
  `claude` CLI (wrapped to always pass `--dangerously-skip-permissions`),
  `@playwright/mcp`, `postgresql-client`, `openssh-client`, and a non-root
  `claude` user whose UID/GID match the host's.

Then on the host: open `http://localhost:3140` — or whatever `PORT` resolves
to, if you have moved it (see `scripts/detect-ports.sh`).

## Locked egress (yolo only)

`make yolo` runs with its outbound traffic locked; `make yolo INTERNET=1` (or
`./run.sh +internet`) opts out. `make box` is never locked. Sidecars, brought up
by `depends_on` in `docker-compose.locked.yml`:

- **egress** (tinyproxy) — the only route out. Forwards solely to hosts matching
  `tinyproxy.filter`, configured by `tinyproxy.conf`, built from
  `tinyproxy.Dockerfile`. Reached via `HTTPS_PROXY=http://egress:8888`.
- **ingress**, **ingress-shadow** (socat) — host → container forwarders for the
  JVM and shadow-cljs ports. Needed because Docker silently drops published
  ports on a container attached only to an `internal: true` network. Their
  commands come from the generated `compose.ports.locked.yml`.

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
docker volume rm rhizome_m2_cache rhizome_node_modules rhizome_shadow_cache
```

The `ollama` sidecar (`WITH_VEC=1`) joins `locked` and **not** `outside`, so it
cannot fetch a model at runtime. Dual-homing it would let anything in the box
ask it to `POST /api/pull` a name like `some.host/ns/model` — an unauthenticated
way out past the filter. Seed the model once from open mode instead:

```bash
make yolo WITH_VEC=1 INTERNET=1    # pulls qwen3-embedding:0.6b into ollama_models
make yolo WITH_VEC=1               # locked from here on; model served offline
```

On a cold `ollama_models` volume in locked mode, `entrypoint.sh` logs
`model pull failed` and continues with semsearch unavailable.

Verify from inside the box:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/  # reaches proxy
curl --max-time 5 -sS https://example.com/                            # blocked
# Not merely unset-proxy-able: the internal network has no gateway either.
env -u HTTPS_PROXY -u HTTP_PROXY bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443'
```

## SQLITE Vec

Off by default. Set `WITH_VEC=1` when building to enable semantic search;
the image then bundles `sqlite-vec`, Ollama, and the `qwen3-embedding:0.6b`
model, so semsearch works inside the container with no host-side install.

The model is the one part that lives in a volume rather than the image, so under
locked egress it has to be seeded once — see "Locked egress" above.

Vector-dependent tests are tagged `^:vector`. `make test` looks at
`:semsearch :vec-path` in `config.edn` and adds `--exclude :vector` if
the dylib it points at isn't on disk. To force-skip even when vec is
installed, remove the `:semsearch` block from `config.edn`.
