# Deploy

Soundboard ships as native apps; nothing runs on a server in 0.1.0. `deploy/` holds the containers
used to build and check the engine and to serve the docs site the same way on any machine.

## Containers

| Service | What it does | Command |
|---|---|---|
| `engine` | Builds the engine on Debian, runs the tests and the routing prototype, then exits | `docker compose -f deploy/compose.yaml run --rm engine` |
| `site` | Serves `public/` at <http://localhost:8052/> | `make up` · `make down` |

Both build from `deploy/Dockerfile` (targets `engine` and `site`).

## Apple release (not yet set up)

1. Set the bundle identifiers and team listed in [dev logins](dev-logins.md).
2. Bump the version everywhere `tools/station/check.mjs` compares (see [QA](qa.md)).
3. Product › Archive in Xcode for the Soundboard scheme; upload with the Organizer.

## Android release (not yet set up)

1. Create a release keystore outside the repository; never use the debug keystore.
2. Add a `release` signing config that reads the keystore path and passwords from Gradle properties
   in `~/.gradle/gradle.properties`, not from the repository.
3. `gradle :app:bundleRelease`.

## Docs site

`public/` is a static folder with relative links, so it opens from disk. It is internal
documentation (`tier: internal` in `station.json`) and is not published to `station.center`.
