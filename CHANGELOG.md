# Changelog

All notable changes to ora are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release notes for a given version are extracted from this file by
`scripts/create-release.sh` and posted to the matching GitHub Release,
so keep each version section self-contained and user-facing.

## [Unreleased]

### Added
- **NVIDIA Nemotron 3.5 ASR Streaming 0.6B** local model for Asian and
  European languages: Chinese (Mandarin, Simplified and Traditional),
  Japanese, Korean, Vietnamese, Hindi and about 30 more. Live preview,
  punctuation built in, and a pinnable language in its settings.
- **SenseVoice Small** local model (Alibaba FunAudioLLM), Chinese-first:
  Mandarin and Cantonese, plus English, Japanese and Korean, detected
  automatically. Live preview, punctuation built in, 240 MB.
- **Copy Last Transcription** in the menu bar menu copies your most
  recent dictation to the clipboard — handy if the paste landed in the
  wrong place. Kept in memory only, never saved to disk.

### Removed
- The Whisper local models (Tiny, Small, Distil-Large-v3,
  Large-v3-Turbo) and the WhisperKit dependency. If a Whisper model was
  selected, Ora switches to Parakeet v3. Files you already downloaded
  stay on disk; delete `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml` to
  free the space.
- The Qwen3-ASR local models (0.6B, 1.7B) and the MLX dependency. If one
  was selected, Ora switches to Parakeet v3. Downloaded files stay in
  `~/.cache/huggingface/hub/mlx-audio`; delete the
  `mlx-community_Qwen3-ASR-*` folders there to free the space.

## [0.6.1] - 2026-11-11

### Fixed
- The live-preview bubble no longer jumps each time the transcript wraps
  onto a new line — it now grows smoothly upward from the pill.
- The Dictation Display preview in Settings → General no longer makes
  the whole page jump down and back while its demo text scrolls.

## [0.6.0] - 2026-11-11

### Added
- **NVIDIA Nemotron Unified ASR 0.6B** local model (25 European
  languages, live preview, punctuation built in). Its settings let you
  pin the language — pick French and it transcribes French, instead of
  auto-detecting and mixing in English words the way Parakeet v3 can.
- Live preview now shows in its own bubble above the pill, with the
  newest line right above the waveform.

### Changed
- New dictation pill: a compact 72×30 capsule with a livelier 6-bar
  waveform and a spinner while transcribing. On macOS 26 and later the
  pill and preview bubble use a dark frosted-glass surface.
- Cancelling a dictation is now Esc only (the hover × is gone).
- Updates now come from the ocai-labs/ora releases. If you're on 0.5.6
  or earlier, install this version manually once; later versions update
  automatically.

## [0.5.6] - 2026-06-20

### Fixed
- In toggle mode, the text pasted after dictation could be your previous
  clipboard contents instead of what you just dictated. Ora now waits for
  the activation key to be released before inserting the transcript, so it
  lands reliably and your existing clipboard is left untouched.

## [0.5.5] - 2026-06-14

### Fixed
- The first dictation after downloading or switching to a local model
  could hang for tens of seconds — or briefly look like the model was
  unavailable — while the model loaded and ran its one-time, first-use
  warm-up. Ora now warms the selected model in the background (when you
  pick it, when its download finishes, and at launch for your saved
  model), so the first hotkey press is as responsive as the rest.

## [0.5.4] - 2026-06-10

### Fixed
- Recording could silently produce nothing (or a "stop() called while
  no recording was in progress" error pill) after cancelling a
  dictation and quickly starting another. The recorder's audio buffer
  was shared across sessions, so the old session's teardown could
  steal or wipe the new session's audio; each recording session now
  owns its buffer end-to-end.
- An audio-engine start that completed *after* the 10-second timeout
  had already fired was left running forever — holding the microphone
  open and corrupting later recordings. The late engine is now torn
  down immediately.
- In Toggle mode, pressing the hotkey a second time while the engine
  was still starting was silently ignored, leaving the recording
  running until another press. The stop now applies as soon as the
  engine finishes booting.
- The global hotkey could die permanently if its event tap failed to
  create once (e.g. an Accessibility race at launch); re-registering
  now retries tap creation.
- Cancelling during the paste tail restored the clipboard too early,
  which could make the target app paste the old clipboard contents
  instead of the transcript. The restore delay is now cancel-proof,
  the clipboard is restored if posting Cmd+V fails, and the restore
  is skipped if something else wrote the clipboard in the meantime.
- Qwen3-ASR (MLX) inference ran synchronously on the main thread,
  freezing the UI for the duration of transcription on long
  dictations. It now runs on a background queue.
- Cancelling a dictation now skips the (discarded) local inference
  pass instead of running it to completion — which also delayed the
  next dictation behind it.
- Onboarding's "Grant Access" for Accessibility opened System
  Settings without registering Ora in the list; it now seeds the
  entry first so the toggle is right there.
- Model download cards could get stuck showing "downloading" after a
  pause or completion (a late progress tick overwrote the final
  state), and deleting a model mid-download no longer lets the
  half-cancelled download resurrect the deleted model's card.
- Launching at login no longer steals focus from the app you're
  working in.
- Opening a Settings page from the menu bar reliably raises the
  Settings window again — the lookup broke once the window title
  changed to the selected page's name after the first navigation.
- The overlay's cancel × only appears when the cursor is actually
  over the pill, not anywhere in the invisible strip beside it.
- The input-device list no longer holds stale device handles after
  unplugging and replugging the same microphone.
- API error responses that fail to parse now log the decode error and
  a body snippet to Console instead of discarding all debugging
  signal.
- A wedged model load (stuck CoreML specialization, stalled network
  fetch) no longer hangs every future dictation until relaunch. Loads
  now time out after 5 minutes with a "Model load timed out" pill, and
  the next dictation retries fresh.
- Releasing the activation key while its left/right sibling was held
  (e.g. releasing Right ⇧ with Left ⇧ down) no longer leaves the
  recording stuck — press/release detection now reads the
  device-specific modifier bits instead of only the family flag.
- An interrupted model download is no longer mistaken for an installed
  model. Whisper models now require all three compiled components (and
  their core blobs); Qwen models require config, tokenizer, and every
  weight shard listed in the checkpoint index. Downloads are also
  verified on completion, so a silently-partial result surfaces as
  "Download finished with files missing" instead of a model that's
  "installed" but fails on every dictation.
- Fixed two rare crash windows: an NSPanel over-release when the
  recording overlay closed, and a use-after-free when an event-tap
  monitor was torn down while its callback was mid-flight.
- Model download progress no longer scans gigabytes of files on the
  main thread every 2 seconds — the disk poller now runs in the
  background, removing periodic UI stutter during downloads.
- Cloud transcription no longer encodes the recording to AAC on the
  main thread; long dictations previously froze the overlay for the
  duration of the encode.
- Clearing an API key now reports failure instead of silently leaving
  the old key in the Keychain; keychain read errors (e.g. locked
  keychain) are logged instead of looking identical to "no key
  configured"; and the settings sheet keeps itself open with an error
  message when saving the key fails, rather than dismissing as if it
  succeeded. A failed migration of a legacy plaintext key no longer
  deletes the only copy of that key.

## [0.5.3] - 2026-05-22

### Fixed
- App no longer freezes after multi-day runs. When CoreAudio stalled
  (a known macOS quirk after sleep/wake, device hotplug, or a stuck
  `coreaudiod`), Ora's audio engine setup ran on the main thread and
  could deadlock the entire process — including the menu bar icon and
  the ESC escape hatch. Engine setup now happens on a background
  thread with a 10-second timeout, so transient CoreAudio hiccups
  surface as a normal error pill instead of a hung UI.
- Global hotkey and ESC could silently stop responding after macOS
  disabled their event taps (which it does on callback timeouts and
  certain system events). Both taps now auto-recover.
- Cloud transcription (OpenAI / Groq) no longer hangs forever when a
  request stalls mid-response. Requests now time out at 60 s between
  bytes / 120 s total, so a flaky connection surfaces an error
  instead of leaving you stuck in "Transcribing".

## [0.5.2] - 2026-04-19

### Added
- Cancel an in-flight dictation. Press ESC while the overlay is up to
  drop the current recording without transcribing or pasting, or hover
  the pill and click the cancel control. Works in both Toggle and
  Push-to-Talk modes. Partially addresses issue #3 — API requests that
  previously hung when offline can now be aborted.

### Fixed
- First dictation after downloading a WhisperKit model no longer
  hangs for 1–2 minutes on CoreML specialization. Ora now pre-warms
  the pipeline the moment the download finishes, while the user is
  still on the Models page, so the first hotkey press is snappy.

## [0.5.1] - 2026-04-13

### Changed
- Lowered minimum system requirement from macOS 26.2 (Tahoe) to
  macOS 14 (Sonoma). Ora now runs on Sonoma, Sequoia, and Tahoe.
  Apple Silicon only — MLX and the on-device transcription stack
  require a Metal-capable Apple GPU.
- Added a classic (pre-Tahoe) app icon variant so the Dock and
  Finder show a proper icon on Sonoma and Sequoia. Tahoe continues
  to use the Liquid Glass icon.

## [0.5] - 2026-04-13

### Added
- Qwen3-ASR local models via MLX. Two new entries on the Models page:
  Qwen3-ASR 0.6B (~960 MB) and 1.7B (~2 GB). Download routes through
  HuggingFace Hub and runs on Apple Silicon via mlx-audio-swift.
- WhisperKit local models. Four new entries on the Models page:
  Whisper Tiny, Small, Distil-Large-v3, and Large-v3-Turbo. Runs via
  CoreML on ANE/GPU for non-European languages and compatibility with
  existing Whisper workflows.
- Parakeet v2 alongside v3. v2 is kept as a fallback for users whose
  hardware struggles with v3.
- Circular download progress indicator on model cards. Fraction is
  computed from filesystem polling so the UI matches what's actually
  on disk (FluidAudio's internal progress stream was unreliable).

### Changed
- Model card UX. The settings gear on each card now opens a sheet
  with details and download / delete controls, instead of cluttering
  the card itself. Local and API cards now share a single component.
- Releases moved to a dedicated public repo
  (github.com/KristampsWong/ora) so the main source repo can
  go private. The Sparkle auto-update feed has been updated — existing
  users will migrate automatically on next update.

### Fixed
- Auto Paste toggle now actually takes effect. When disabled, the
  transcribed text is copied to the clipboard only — Ora no longer
  simulates a Cmd+V paste. Previously the toggle was bound to the UI
  switch but never consulted by the dictation pipeline.
- MLX download progress and ETA. Fixed a bug where Ora counted other
  apps' concurrent URLSession downloads as its own, inflating the
  progress number. Also corrected displayed model sizes to match the
  actual on-disk footprint.
- MLX cache path resolution. Fixed a missing path component that
  caused Qwen3-ASR downloads to land in the wrong directory.
- WhisperKit cache path to match the default HubApi location, so
  `isInstalled` correctly detects downloaded models.
- Silenced noisy per-chunk download progress logs from
  mlx-audio-swift that were polluting the Xcode console.

## [0.4] - 2026-04-11

### Added
- Cloud transcription providers. The OpenAI and Groq cards on the
  Models page are now live end-to-end: open the gear to paste an API
  key and model name (e.g. `gpt-4o-transcribe`, `whisper-large-v3`),
  select the card, and dictation routes to the provider instead of
  the local Parakeet model. Audio is encoded to AAC/m4a before upload
  so uploads stay small on slow networks.
- Toggle activation mode. Settings ▸ Dictation ▸ Input mode now
  actually flips behavior — "Toggle" means press once to start and
  press again to stop, while "Push to Talk" keeps the original
  hold-to-dictate behavior.

### Changed
- API keys now live in the login Keychain instead of plaintext
  UserDefaults. Existing installs are migrated automatically the
  first time you open an API provider's settings sheet, and the old
  UserDefaults copy is wiped. The settings sheet also gains an
  explicit Cancel / Done split, so edits only persist when you hit
  Done.
- App icon swapped to a minimal slash mark on a dark squircle.

## [0.3.1] - 2026-04-11

### Fixed
- App now displays as **Ora** (capitalized) in Finder, Dock, the menu
  bar, and the About window. The bundle identifier is unchanged, so
  existing installs upgrade in place.
- DMG installer now ships with a drag-to-Applications shortcut, so new
  users can install without opening a second Finder window. The release
  script requires `create-dmg` (`brew install create-dmg`) and will
  fail fast instead of silently falling back to a bare DMG.

## [0.3] - 2026-04-11

### Added
- Liquid Glass app icon (Icon Composer `.icon` bundle) so the app no
  longer renders inside the macOS 26 auto-applied white container, plus
  a custom menu bar template image in place of the waveform SF symbol.
- Provider brand icons on the Models page. Parakeet v2/v3 cards now
  show the NVIDIA mark, OpenAI API shows the OpenAI mark, and Groq API
  shows the Groq mark; cards without a brand asset fall back to the
  previous SF Symbol.

### Changed
- Menu bar dropdown is now Models / General / Dictation / Quit. The
  Input Source submenu, inline version label, and Check-for-Updates
  entry have moved into Settings where they belong, and menu items
  activate the app so Settings doesn't get hidden behind other windows.
- Input Source (now labeled "Microphone") and Notification Sound moved
  from General to the Dictation settings page — they only matter for
  transcription.
- Settings › General › Installed now shows the marketing version and
  git commit hash, generated at build time from the latest git tag.
  Debug builds render as `0.3-dev (abc1234)` so they're easy to tell
  apart from release builds.

## [0.2] - 2026-04-10

### Added
- Sparkle-powered automatic updates. The General settings page now
  includes a "Check for Updates…" button, and ora checks for updates
  in the background on launch.
- Input source selection. General settings now lets you pin a specific
  microphone for dictation, or follow the system default.
- Appearance preference (System / Light / Dark) and configurable
  notification sound, wired into the General settings page.
