# docker-rhizome

Run Rhizome dev (and Claude Code) inside an isolated container.

## What's inside the container

JDK 21 + `clj`, Node + npm, system Chromium for Playwright, `claude` CLI
(wrapped to always pass `--dangerously-skip-permissions`), `gh`, `make`,
`postgresql-client`, `lsof`.

Then on the host: open `http://localhost:3006` (or `:8020`).

## SQLITE Vec

By default this is on, and as such might expect ollama to run on the host system.

To toggle it off for the current container session:

```bash
rm /usr/local/lib/sqlite-vec/vec0.so
```

While the file is gone, `et.vp.ds.search-test` self-skips (the `:once`
fixture sees `vec-available?` as false and prints `Skipping
et.vp.ds.search-test: sqlite-vec extension not installed.`), and any
runtime semantic-search query becomes a no-op. The image rebakes the file
on the next `make yolo`.
