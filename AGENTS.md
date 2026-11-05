# AGENTS

For an AI agent (and any person) working in this repository: what to read, what to run, and what
never to do.

## Read

1. [station.json](station.json): what this is, its version and status.
2. [.station/STATUS.md](.station/STATUS.md): what passes, what is open, which jobs exist.
3. [docs/README.md](docs/README.md): where each topic lives.
4. [docs/architecture.md](docs/architecture.md) before touching `engine/` or `platforms/`.
5. [docs/design/appearance.md](docs/design/appearance.md) before touching UI or tokens.
6. The open job's `SESSION.md` in `.station/jobs/`, or open a new job for new work.

## Run

| Command | When |
|---|---|
| `make setup` | Once per machine: checks the toolchain |
| `make validate` | Before every commit; must be green |
| `make test` | After any change to `engine/` or Swift code |
| `make tokens` | After editing `design/tokens/obsidian.tokens.json` |
| `make site` | After editing docs, AGENTS.md, ROADMAP, CHANGELOG, tokens or the version |
| `make dist` | At a release: writes `dist/soundboard-<version>.zip` and its checksum |

Work goes on a branch, then a pull request, then a merge to `main`. Commits end with the attribution
lines the session gives.

## Never

- Never allocate, lock, log or wait on the audio thread (`render`, `process`, anything called from
  an audio callback). Commands go through the lock-free queue; memory is released by generation.
- Never let anything reach the master bus because of a cue, preview or headphone action. The routing
  prototype's bit-identical check is the proof; keep it passing.
- Never edit a generated file. Each carries a "Generated … do not edit" header; change its source and
  re-run its generator. `make validate` fails on drift.
- Never write a raw colour, size or font in UI or site code. Use semantic tokens.
- Never delete something questionable. Move it to `.archives/removal-safe/<name>/` with a README.
- Never commit secrets, signing identities, provisioning profiles or `local.properties`.
- Never rely on the hardware volume buttons for mixing, or route cue audio to Bluetooth.
- Never push to `main` directly, rewrite published history, or move a release tag.
