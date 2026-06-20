# Ora

[![Latest release](https://img.shields.io/github/v/release/KristampsWong/ora?display_name=tag&sort=semver&label=latest)](https://github.com/KristampsWong/ora/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/KristampsWong/ora/total?label=downloads)](https://github.com/KristampsWong/ora/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

Local, private dictation for macOS. Press a hotkey, speak, release — your words are transcribed on-device and pasted into whatever app you're using.

This is the open-source home for Ora: the full app source plus the signed/notarized DMG and Sparkle appcast under [Releases](https://github.com/KristampsWong/ora/releases).

## Install

**[→ Download Ora.dmg (latest)](https://github.com/KristampsWong/ora/releases/latest/download/Ora.dmg)**

1. The download starts immediately.
2. Open the DMG and drag **Ora** onto the Applications shortcut.
3. Launch Ora from Applications. On first launch it'll walk you through microphone + accessibility permissions and downloading a Whisper model.

Ora is signed with a Developer ID and notarized by Apple, so Gatekeeper will open it without warnings. Updates ship automatically via [Sparkle](https://sparkle-project.org) — once installed, new versions are fetched in the background and you're prompted to restart.

### Requirements

- macOS 14 (Sonoma) or later, Apple Silicon only
- Microphone permission
- Accessibility permission (so Ora can paste into other apps)

Building from source additionally needs Xcode 26+ — see [Build from source](#build-from-source) below.

## Privacy

Ora is built around a simple rule: **your voice never leaves your Mac.**

- **No network calls for transcription.** Whisper models run entirely on-device via [FluidAudio](https://github.com/FluidInference/FluidAudio). Audio is captured, transcribed, and discarded locally.
- **No telemetry, no analytics, no crash reporting.** Ora does not phone home and has no server-side component. The only outbound network traffic is Sparkle checking GitHub for new release DMGs — and you can turn that off in Settings.
- **Models live in your own Application Support directory.** Download and delete them from Settings; nothing is hidden.

If you're dictating something sensitive and want belt-and-suspenders confirmation, throw Ora into Little Snitch or disconnect Wi-Fi: transcription will keep working exactly the same.

## Features

- **Global hotkey** (Option+Space) — hold to record, release to transcribe and paste
- **On-device transcription** — multiple Whisper-family models via FluidAudio, switchable from Settings
- **Works everywhere** — pastes into any app with a text field
- **Menu-bar app** — lives in your status bar, out of the way
- **Auto-updates** — signed, notarized releases via Sparkle

## Build from source

No Apple Developer account required — the project uses ad-hoc signing (`Sign to Run Locally`) out of the box.

```bash
git clone https://github.com/KristampsWong/ora.git
cd ora
./scripts/dev-launch.sh
```

The script builds the project and launches Ora via Launch Services, so permission prompts attribute to Ora correctly.

### Dev scripts

| Script | Purpose |
|--------|---------|
| `scripts/dev-launch.sh` | Build and launch via Launch Services — permission prompts attribute to Ora correctly |
| `scripts/dev-run.sh` | Build and launch with stdout/stderr streaming to your terminal (useful for debugging) |
| `scripts/dev-reset.sh` | Wipe TCC entries and UserDefaults for a clean first-run experience |

### Custom code signing (optional)

Only needed if you want to sign with your own Apple Developer identity:

```bash
cp scripts/dev-env.local.sh.example scripts/dev-env.local.sh
# edit with your SIGN_IDENTITY and TEAM values
```

This file is gitignored and will never be committed.

## License

Ora is free software licensed under the [GNU General Public License v3.0](LICENSE).
You may use, study, share, and modify it; derivative works you distribute must
also be released under the GPLv3.

© Ora contributors
