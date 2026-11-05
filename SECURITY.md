# Security

Report a vulnerability privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**, or go to
<https://github.com/aidenlive/Soundboard/security/advisories/new>. Do not open a public issue.

Include the platform and version, steps to reproduce, and what an attacker gains.

## Scope

| In scope | Notes |
|---|---|
| The apps (iOS, Android, macOS) | File import, security-scoped bookmarks, audio file parsing |
| The engine (`engine/`) | Memory safety in decoding hand-off, analysis and the real-time path |
| Build and CI configuration | `.github/`, `deploy/`, `Makefile`, `tools/` |

The apps have no server, accounts or network API in 0.1.0. Sync (planned, see
[ROADMAP.md](ROADMAP.md)) will extend this scope when it ships.

## Supported versions

Only the latest version on `main` receives fixes while the project is in `draft`.
