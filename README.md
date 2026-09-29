# TinyFire

> If you're burning tokens anyway, light a real fire.  
> 既然都在烧 token，不如真的生一把火。

TinyFire is a floating macOS campfire driven by your local AI coding-tool token usage. Codex, Claude Code, Cursor, Grok, Pi, Amp, DeepSeek Harness — as you burn tokens, the fire grows; when you stop, it settles into embers.

Nothing is uploaded for usage tracking. Logs stay on your Mac.

![TinyFire](branding/desktop-hearth-zoom.gif)

## Download

[**TinyFire-1.1.17.dmg**](https://github.com/wdkwdkwdk/tinyfire/releases/download/v1.1.17/TinyFire-1.1.17.dmg)

## Features

- Floating pixel campfire on the desktop (draggable, hideable, non-activating)
- Hover card for today's tokens + per-source breakdown
- Console: stats, flame colors, sources, size, language, website / developer links
- Languages: English / 中文 / 日本語 / 한국어 (+ system)
- Cursor usage prefers the official Dashboard API when a local token is available, otherwise falls back to local estimate
- In-app updates via Sparkle (Release builds); Debug skips update checks
- Console debug panel (tap version 10×) and clickable flame-size previews

## Install from source

```bash
# Xcode 16+, macOS 14+
open tinyFire.xcodeproj
# Product → Run
```

Package a DMG:

```bash
./scripts/make-dmg.sh
# → dist/TinyFire-<version>.dmg
# Then: ./scripts/sparkle-appcast.sh  → backend/public/appcast.xml
```

## Privacy

TinyFire reads **local** usage logs only (and optionally Cursor's local access token for the Dashboard API). Usage data is not uploaded.

## License

MIT
