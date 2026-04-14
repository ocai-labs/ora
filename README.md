# ora-releases

Public distribution channel for [Ora](https://github.com/KristampsWong/ora),
a macOS voice dictation menu bar app.

Release artifacts (DMG + Sparkle appcast) are published here so the main
source repository can stay private while auto-updates keep working.

## Install

Grab the latest DMG from the [Releases](https://github.com/KristampsWong/ora-releases/releases)
page, open it, and drag Ora onto the Applications shortcut.

After installation, Ora auto-updates via Sparkle — the feed at
`releases/latest/download/appcast.xml` is polled on launch.
