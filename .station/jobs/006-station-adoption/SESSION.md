# Job 006 · station adoption

Status: DONE

## Objective

Bring the repository to Station 1.2.1 and its delivery checklist, and release it as 0.1.0.

## Completed

- Root files: AGENTS, ROADMAP (by version), CHANGELOG, LICENSE, SECURITY, CONTRIBUTORS, `station.json`, five-section README with a screenshot.
- `.station/`: config, STATUS, jobs 001 to 009 with eight-heading SESSION files.
- Docs: overview, guides (local development, deploy, dev logins, QA), six ADRs, architecture sections for boundaries, data model, surfaces and testing.
- Design: space, radius, type roles and elevation added as tokens; `generate.py` writes Swift, `tokens.css`, `tokens.json` and `DESIGN.md`, with `--check`.
- Public surface: landing page with a figure drawn from real engine output, docs site, design kit, system graph, `llm.txt`, root `index.html`.
- Tooling: Makefile, site generator, Station lint, dev-logins check, dependency pin check, e2e, screenshots, dist; `deploy/` Dockerfile and compose; CI `validate` job; issue and PR templates.
- Archive: `docs/roadmap.md` moved to `.archives/removal-safe/`; audit reports 000 and 001.

## Active

Nothing.

## Blockers

None for this job. Docker Hub is unreachable from the build workspace, so `make up` was not run there.

## Decisions

- [ADR 0005](../../../docs/decisions/0005-station-layout.md): internal tier, small shape, token JSON as the pinned system.
- ADRs 0001 to 0004 and 0006 record earlier decisions that had no ADR.

## Files changed

Root files listed above, `.station/`, `.archives/`, `.github/`, `deploy/`, `docs/`, `public/`, `tools/`, `design/tokens/generate.py`, `design/tokens/obsidian.tokens.json`, the generated Swift tokens, `engine/README.md`, `Makefile`, `index.html`, `.gitignore`.

## Verification

- `make validate` green on Linux: dependency pins, design tokens, site, dev logins, typecheck (engine with `-Werror`, tool syntax), Station lint, engine tests.
- Each check was shown to fail on a planted fault: token drift, stale site, an undocumented password, an extra README section, a raw CSS colour, a version mismatch, a wrong SESSION heading, a dynamic Gradle version, a broken Markdown link.
- `make e2e`: every page, link, asset and anchor resolves; five top pages render in headless Chrome.
- Screenshots at 390 and 1440 px, dark and light, reviewed.
- Fresh-checkout test from `dist/soundboard-0.1.0.zip`: see audit report 001.
- Not verified here: `swift build` and `swift test` (no Swift toolchain), `make up` (Docker Hub blocked), CI (account billing).

## Next actions

- Owner: run `make validate` on the Mac, which adds the Swift build and tests.
- Keep `make site` and `make validate` in every change; bump the version in all five places at the next release.
