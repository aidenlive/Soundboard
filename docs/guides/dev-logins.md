# Dev logins and defaults

Every development default in this repository, where it is set, and whether to change it for
production. `tools/logins/check.js` (run by `make validate`) fails when a port, account, password,
token or key appears in code or configuration without a row here.

## Accounts

There are none. Soundboard 0.1.0 has no server, no sign-in and no seeded accounts. When sync ships,
seeded accounts will follow `<role>@soundboard.station.center` with password
`demo-placeholder-password`, and be listed here.

## Defaults

| Default | Value | Set in | Change for production |
|---|---|---|---|
| Docs site port | `8052` | `Makefile` (`SITE_PORT`), `tools/site/serve.mjs`, `deploy/compose.yaml` | No: local preview only |
| Apple bundle ID prefix | `com.soundboard` | `platforms/apple/project.yml` (`bundleIdPrefix`) | Yes, to the owner's registered identifier |
| Apple app bundle ID | `com.soundboard.app` | `platforms/apple/project.yml` | Yes, with the prefix |
| Apple signing team | Not set | Xcode › Signing & Capabilities (per machine) | Set by whoever signs a release |
| Android application ID | `com.soundboard.routinglab` | `platforms/android/app/build.gradle.kts` | Yes, before any store build |
| Android debug keystore | `~/.android/debug.keystore`, store and key password `android`, alias `androiddebugkey` | Created by the Android SDK on first debug build | Never ship with it; release signing uses a private keystore outside the repository |
| Engine sample rate fallback | `48000` Hz | `platforms/apple/Sources/SoundboardUI/Model/DJSession.swift`, `RoutingLabModel.swift` | No: used only when the device reports none |

## Secrets, tokens, API keys, buckets, client IDs

None. Nothing in the repository authenticates to anything. `.env.example` does not exist because
no setting comes from the environment.
