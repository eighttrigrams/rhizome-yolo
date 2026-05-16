# docker-rhizome

Run Rhizome dev (and Claude Code) inside an isolated container.

## What's inside the container

JDK 21 + `clj`, Node + npm, system Chromium for Playwright, `claude` CLI
(wrapped to always pass `--dangerously-skip-permissions`), `gh`, `make`,
`postgresql-client`, `lsof`.

Then on the host: open `http://localhost:3006` (or `:8020`).

## SQLITE Vec

Off by default. Set `WITH_VEC=1` when building to enable semantic search;
the image then bundles `sqlite-vec`, Ollama, and the `nomic-embed-text`
model, so semsearch works inside the container with no host-side install.

Vector-dependent tests are tagged `^:vector`. `make test` looks at
`:semsearch :vec-path` in `config.edn` and adds `--exclude :vector` if
the dylib it points at isn't on disk. To force-skip even when vec is
installed, remove the `:semsearch` block from `config.edn`.
