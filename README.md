# docker-rhizome

Run Rhizome dev (and Claude Code) inside an isolated container.

## What's inside the container

JDK 21 + `clj`, Node + npm, system Chromium for Playwright, `claude` CLI
(wrapped to always pass `--dangerously-skip-permissions`), `gh`, `make`,
`postgresql-client`, `lsof`.

## Container ↔ host wiring

- Repo is bind-mounted at `/workspace`.
- `docker-rhizome/config.edn` is bind-mounted **over** `./config.edn` so
  the in-container app talks to the host Postgres at
  `host.docker.internal:5437` (the host file is untouched).
- The host files folder
  `/Users/daniel/Workspace/eighttrigrams/tracker.project/tracker/files/`
  is bind-mounted at the **same path** inside the container, so
  `:homefolder` works without rewrites.
- Ports `3005`, `3006`, `8020`, `9630` are published to the host.

## One-time setup

```bash
claude setup-token       # on host; copy ONLY the REDACTED-TOKEN-PREFIX-oat01-… line
echo 'REDACTED-TOKEN-PREFIX-oat01-…' > docker-rhizome/token
chmod 600 docker-rhizome/token

# Optional: GitHub PAT
echo 'ghp_…' > docker-rhizome/gh_token
chmod 600 docker-rhizome/gh_token

docker compose -f docker-rhizome/docker-compose.yml build
```

Make sure the host Postgres on `:5437` listens on all interfaces (not
just `127.0.0.1`) and `pg_hba.conf` allows the docker bridge subnet —
otherwise `host.docker.internal` connections will be refused.

## Daily use

```bash
cd docker
./run.sh
# inside the container:
make start          # JVM on :3006, shadow on :8020
claude              # interactive Claude, all tools auto-approved
```

Then on the host: open `http://localhost:3006` (or `:8020`).

## Postgres connectivity

Tested working out of the box on macOS Docker Desktop: even when the host
Postgres only listens on `127.0.0.1`, `host.docker.internal:5437` reaches
it (Docker Desktop's VM proxies to host loopback). No `postgresql.conf`
or `pg_hba.conf` changes required.

On Linux, `host.docker.internal` resolves to the bridge gateway via
`extra_hosts: "host.docker.internal:host-gateway"`, but the host
Postgres must then listen on that interface and `pg_hba.conf` must allow
the docker subnet — Linux loopback is not proxied like Docker Desktop's.

## Notes / gotchas

- The container runs as a non-root user (UID 501 / GID 20 to match macOS
  defaults). Override via `USER_UID` / `USER_GID` build args on Linux.
- Playwright uses system Chromium (`/usr/bin/chromium`) — bundled
  Chromium is glibc-only and won't run on Alpine.
- Don't commit `./token` or `./gh_token`.
