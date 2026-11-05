# Soundboard documentation

Soundboard is a DJ app for iPhone, Android and Mac. One C++ engine does all audio, with a master
bus for the room and a separate cue bus for headphones. Thin native apps sit on top, sharing one
design system. This page says where each topic lives.

| You want to | Read |
|---|---|
| Build and run the apps | [Local development](guides/local-development.md) |
| Know what each platform can do for headphone cueing | [Platform audio research](research/platform-audio.md) |
| Understand the engine, threads, routing and data model | [Architecture](architecture.md) |
| See why the product works the way it does | [Product](product.md) |
| Change colours, themes or waveform schemes | [Design system](design/appearance.md) |
| Use the logo or app icon | [Brand](brand.md) |
| Test on hardware or before a release | [QA](guides/qa.md) |
| Ship a build or run the docs site in Docker | [Deploy](guides/deploy.md) |
| Find a default account, port or key | [Dev logins](guides/dev-logins.md) |
| Know why a decision was made | [Decisions](decisions/) |
| Know what is next | [ROADMAP.md](../ROADMAP.md) |

## One-minute start

```bash
make setup
make validate
make dev
```

`make dev` opens the Xcode project on a Mac. Run the **Soundboard** scheme; import a few audio
files from Files; tap **Mix**.

## How headphone cueing works on each platform

| | Device alone | Splitter cable | USB interface or controller | Two outputs at once |
|---|---|---|---|---|
| iPhone | Master only | Mono master + mono cue | Yes | USB, HDMI or line-out plus headphones (multi-route) |
| Android | Master only | Yes | Yes | Depends on the phone; checked at runtime |
| Mac | Two devices (speakers + headphone jack) | Yes | Yes | Yes, drift-compensated |

Where cueing is not possible, the app says so and still offers sync, visual beat-matching and
phrase-aligned automatic transitions. Details and sources: [platform audio research](research/platform-audio.md).
