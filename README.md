# docker-rhizome

Run Rhizome dev (and Claude Code) inside an isolated container.

## What's inside the container

JDK 21 + `clj`, Node + npm, system Chromium for Playwright, `claude` CLI
(wrapped to always pass `--dangerously-skip-permissions`), `gh`, `make`,
`postgresql-client`, `lsof`.

Then on the host: open `http://localhost:3006` (or `:8020`).

## SQLITE Vec

By default this is on, and as such might expect ollama to run on the host system.

Vector-dependent tests are tagged `^:vector`. `make test` auto-detects
whether the extension file is on disk and adds `--exclude :vector` if
not — so on a host without sqlite-vec installed, those tests just skip
quietly. To force-skip even when vec is installed:

```bash
SQLITE_VEC_PATH=/nope make test
```
