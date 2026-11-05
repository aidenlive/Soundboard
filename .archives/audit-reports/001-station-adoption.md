# 001 · Station adoption: completed summary

Date: 2026-11-05 · Job [006](../../.station/jobs/006-station-adoption/SESSION.md) · Release 0.1.0

## Brief

Make the repository follow Station 1.2.1 and its delivery checklist. Starting point:
[000](000-initial-assessment.md).

## Findings that shaped the work

- Private repository in a personal account → `tier: internal`, `landing` is the GitHub repository,
  `sponsor: null` ([ADR 0005](../../docs/decisions/0005-station-layout.md)).
- No HTTP API or MCP server → no `api/openapi.yaml`, no `public/docs/openapi.yaml`; `llm.txt` and
  the resource page say so. The engine's C API gets a reference page instead.
- Several native builds but no deployable services → small shape; `engine/` and `platforms/` stand
  in for `src/`.
- The token JSON already drove Swift → it stays the pinned system, and DESIGN.md, CSS and JSON are
  generated from it.
- No lockfile exists to check → the "lockfile platform check" step checks dependency pins instead.

## What changed

| Checklist section | Now |
|---|---|
| 1 Root files | All present, including `deploy/`, `public/`, `index.html`, Makefile with every required target |
| 2 Manifest | `station.json` complete; version 0.1.0 agrees with CHANGELOG, CMake, Xcode and Android |
| 3 README | Five sections in order, landing screenshot, annotated layout, links, internal sponsor line |
| 4 `.station/` | config, STATUS (passes, Open table, Jobs), jobs 001 to 009 |
| 5 Docs | Overview page, four guides, dev-logins check, six ADRs |
| 6 Public surface | Landing, docs site (grouped sidebar, on-this-page, previous and next), design kit, system graph, `llm.txt`, self-hosted fonts; all generated regions checked |
| 7 Root resource page | Generated `index.html` |
| 8 Design and content | Tokens for colour, type, space, radius, elevation; site CSS uses tokens only; light and dark, 390 and 1440 px reviewed |
| 9 Quality gates | `make validate` in the required order; `make e2e`; CI runs `make validate` |
| 10 Archive | `docs/roadmap.md` moved with a README; this report and 000 |
| 11 Release | CHANGELOG 0.1.0; `make dist` zip and checksum; tag `v0.1.0` on the merge commit |

## Verification

- `make validate` green in the build workspace.
- Nine planted faults, one per check, each made its check fail (listed in the job's SESSION).
- `make e2e`: 29 pages and 1,565 links and assets resolve; five pages render in headless Chrome.
- Fresh-checkout test: `dist/soundboard-0.1.0.zip` extracted into an empty directory with no git
  history; `make validate`, `make build` and `make e2e` all pass there.

## Not done

| Item | Why | Owner |
|---|---|---|
| `swift build` and `swift test` under `make validate` | No Swift toolchain in the build workspace; the Makefile runs them on macOS | aidenlive |
| `make up` | Docker Hub unreachable from the build workspace | aidenlive |
| CI run | GitHub Actions blocked by account billing | aidenlive |
| `npx @stationprotocol/station check` | The Station CLI was not run; `tools/station/check.mjs` covers this repository's rules | aidenlive |
| Swift views use the new `space` and `radius` tokens | Planned for 0.3.0 in ROADMAP.md | Claude |
