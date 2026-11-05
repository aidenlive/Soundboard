# 0005 · Adopt Station 1.2.1 as an internal, small-shape repository

Status · Accepted · 2026-11-05

## Context

The owner asked for the Station 1.2.1 repository protocol. The repository is private and belongs to a personal account. It has one product with several native builds but no deployable services, no HTTP API and no MCP server.

## Decision

- `tier: internal`, `landing` = the GitHub repository, `sponsor: null`. `public/` is internal documentation.
- Small shape: `engine/` and `platforms/` stand in for `src/`; no `apps/` or `packages/`, so no `api/openapi.yaml`.
- `design/tokens/obsidian.tokens.json` is the pinned system. `design/tokens/generate.py` writes Swift, `public/design/tokens.css` and `public/design/DESIGN.md` from it, with `--check` for drift. DESIGN.md is listed in `kept`.
- `tools/` holds zero-dependency Node and Python scripts: site generator, Station lint, dev-logins check, dependency pin check, screenshots, dist.
- `deploy/` holds a Dockerfile and compose for the engine build and the docs site.

## Consequences

- `make validate` is the single gate for people, agents and CI.
- Every doc change needs `make site`; the site check fails otherwise.
- Flipping to `tier: open` later needs a `station.center/modules/soundboard` landing and a sponsor block.
