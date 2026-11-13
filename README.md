<div align="center">

<img src="assets/icon.png" alt="Ora" width="120" />

# Ora

[![Latest release](https://img.shields.io/github/v/release/ocai-labs/ora?display_name=tag&sort=semver&label=latest)](https://github.com/ocai-labs/ora/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ocai-labs/ora/total?label=downloads)](https://github.com/ocai-labs/ora/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

**Local, private voice-to-text for macOS.** Press a hotkey, speak, press it
again — your words are transcribed on-device and pasted into whatever app
you're using.
No cloud round-trip, no account, no telemetry.

<img src="assets/live-preview.gif" alt="Ora live preview — as you speak, the transcript forms in a bubble above the dictation pill and is pasted when you finish" width="760" />

<p>
  <a href="https://github.com/ocai-labs/ora/releases/latest/download/Ora.dmg"><b>↓ Download Ora.dmg</b></a>
  &nbsp;·&nbsp;
  <a href="#install">Install</a>
  &nbsp;·&nbsp;
  <a href="#privacy">Privacy</a>
  &nbsp;·&nbsp;
  <a href="#build-from-source">Build from source</a>
</p>

</div>

## What is Ora?

Ora turns your voice into text anywhere on your Mac. Press **Option+Space**,
talk, and press it again — the transcript lands at your cursor in whatever app has
focus: your editor, browser, chat box, email, terminal. It lives in the menu
bar and stays out of the way until you need it.

Everything runs on Apple Silicon with on-device speech models, so dictation
works offline and your audio never leaves your machine. It's a free,
open-source alternative to the subscription dictation apps — you own the app,
the models, and your data.

## Features

- **Dictate into any app** — the transcript is pasted right where your cursor
  is: editors, browsers, Slack, email, terminals. If you'd rather not auto-paste,
  Ora can just copy to the clipboard instead.
- **Live preview** — with a Parakeet, Nemotron or SenseVoice model, watch the
  text form in a bubble at the bottom of the screen as you speak. Nothing is
  typed until you finish, so your cursor and existing text stay untouched.
- **Make the overlay yours** — in **Settings → Interface**, show or hide the
  recording pill, put it at the bottom (default) or top of the screen, and turn
  live transcription on or off. The overlay is native Liquid Glass on macOS 26
  (a blurred material on older systems) that follows Light / Dark appearance,
  with an optional tint colour and strength. Errors always show a pill, even
  with everything hidden.
- **Your choice of models** — on-device **Parakeet Ultra** and **Nemotron Unified**
  (NVIDIA), and **Nemotron 3.5 Streaming** and **SenseVoice** for Chinese,
  Japanese and Korean, or bring
  your own API key for **OpenAI** / **Groq**. Switch any time from Settings.
- **Pin your language** — Nemotron Unified covers 25 European languages and
  Nemotron 3.5 Streaming about 40 (including Mandarin, Japanese and Korean);
  both let you lock the one you speak (say, French), so it doesn't drift into
  English words mid-sentence. Punctuation is built in.
- **Toggle or push-to-talk** — press the hotkey once to start and again to stop
  (the default), or switch to **Hold** to dictate while the key is down.
  **Return** also finishes a recording (it isn't passed on to the app, so a
  chat box won't send an empty message) — turn that off in Settings →
  Dictation if you'd rather it didn't. Cancel any in-flight dictation with
  **ESC**.
- **Menu-bar app** — no Dock clutter, no window to manage; just a status-bar icon.
  Its menu has **Copy Last Transcription** in case a paste lands in the wrong place.
- **History** — Settings → History keeps your last 25 recordings and their
  transcripts on your Mac. Play one back, copy its text, or **regenerate** it
  with another installed model — handy when a transcription failed, since the
  audio is kept. Turn **Save recordings** off to stop saving and delete them all.
- **Private by default** — local models mean zero network calls for
  transcription. No telemetry, no analytics, no crash reporting, ever.
- **Auto-updates** — signed, notarized releases delivered in the background via
  [Sparkle](https://sparkle-project.org).

<div align="center">
  <img src="assets/models.png" alt="Ora model picker — Parakeet, Nemotron and SenseVoice models, downloadable and switchable from Settings" width="540" />
</div>

## Install

**[→ Download Ora.dmg (latest)](https://github.com/ocai-labs/ora/releases/latest/download/Ora.dmg)**

1. The download starts immediately.
2. Open the DMG and drag **Ora** onto the Applications shortcut.
3. Launch Ora from Applications. On first launch it'll walk you through
   microphone + accessibility permissions and downloading a model.

Ora is signed with a Developer ID and notarized by Apple, so Gatekeeper will
open it without warnings. Updates ship automatically via Sparkle — once
installed, new versions are fetched in the background and you're prompted to
restart.

### Requirements

- macOS 14 (Sonoma) or later, Apple Silicon only
- Microphone permission
- Accessibility permission (so Ora can paste into other apps)

Building from source additionally needs Xcode 26+ — see [Build from source](#build-from-source) below.

## Privacy

Ora is built around a simple rule: **your voice never leaves your Mac.**

- **No network calls for transcription.** On-device Parakeet, Nemotron,
  and SenseVoice models run entirely locally via [FluidAudio](https://github.com/FluidInference/FluidAudio).
  Audio is captured and transcribed on your machine.
  *(The optional OpenAI / Groq backends are the one exception — they upload
  audio to that provider, and only if you explicitly choose one.)*
- **No telemetry, no analytics, no crash reporting.** Ora does not phone home
  and has no server-side component. The only outbound network traffic is
  Sparkle checking GitHub for new release DMGs — and you can turn that off in
  Settings.
- **Models live in your own Application Support directory.** Download and delete
  them from Settings; nothing is hidden.
- **History stays on your Mac.** Your last 25 recordings and their transcripts
  are saved locally (in `~/Library/Application Support/Ora/History`) so you can
  replay, copy or regenerate them — never uploaded anywhere. Delete one, clear
  them all, or turn **Save recordings** off in Settings → History to delete
  them and stop saving new ones.

If you're dictating something sensitive and want belt-and-suspenders
confirmation, throw Ora into Little Snitch or disconnect Wi-Fi: transcription
with a local model will keep working exactly the same.

## Build from source

No Apple Developer account required — the project uses ad-hoc signing
(`Sign to Run Locally`) out of the box.

```bash
git clone https://github.com/ocai-labs/ora.git
cd ora
./scripts/dev-launch.sh
```

The script builds the project and launches Ora via Launch Services, so
permission prompts attribute to Ora correctly.

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
