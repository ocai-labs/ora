# Ora — Releases

[![Latest release](https://img.shields.io/github/v/release/KristampsWong/ora-releases?display_name=tag&sort=semver&label=latest)](https://github.com/KristampsWong/ora-releases/releases/latest)
[![Total downloads](https://img.shields.io/github/downloads/KristampsWong/ora-releases/total?label=downloads)](https://github.com/KristampsWong/ora-releases/releases)
[![Downloads (latest)](https://img.shields.io/github/downloads/KristampsWong/ora-releases/latest/total?label=latest%20downloads)](https://github.com/KristampsWong/ora-releases/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

**Ora** is a local, private dictation app for macOS. Hold a hotkey (Option+Space), speak, release — your words are transcribed on-device with Whisper and pasted into whatever app you're using. No network calls for transcription, no telemetry, no account.

This repository is the **public distribution channel** for Ora. The app's source lives in a separate private repository; signed, notarized DMGs and the Sparkle appcast are published here so that:

- anyone can download Ora without a GitHub account or special access, and
- existing installs can keep auto-updating via Sparkle.

## Download

**[→ Download Ora.dmg (latest)](https://github.com/KristampsWong/ora-releases/releases/latest/download/Ora.dmg)**

1. The download starts immediately.
2. Open the DMG and drag **Ora** onto the Applications shortcut.
3. Launch Ora from Applications and follow the first-run setup (microphone + accessibility permissions, Whisper model download).

Ora is signed with a Developer ID and notarized by Apple, so Gatekeeper opens it without warnings.

> The `Ora.dmg` filename is a stable redirect to the newest version. To grab a specific version, browse the [releases page](https://github.com/KristampsWong/ora-releases/releases).

### Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or newer)
- Microphone permission
- Accessibility permission (so Ora can paste into other apps)

## Updates

Once installed, Ora checks this repo for new versions on launch via [Sparkle](https://sparkle-project.org). Updates download in the background; you're prompted before they're applied. You can disable update checks from Ora's Settings.

The Sparkle feed lives at:
`https://github.com/KristampsWong/ora-releases/releases/latest/download/appcast.xml`
