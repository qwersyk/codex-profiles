# Codex Profiles

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/1b.png">
  <source media="(prefers-color-scheme: light)" srcset="screenshots/1w.png">
  <img alt="Codex Profiles screenshot" src="screenshots/1w.png">
</picture>

Small native macOS app for saving and loading local Codex profiles.

## Saved files

- `~/.codex/auth.json`
- `~/.codex/config.toml`

## Features

- Current profile highlight
- Replace existing profile when the same email is saved again
- Rename, delete and avatar selection
- Compact toolbar actions

## Shortcuts

- `Cmd+N` add current profile
- `Cmd+R` refresh
- `Shift+Cmd+R` restart Codex

## Build

```bash
chmod +x Scripts/build_app.sh Scripts/build_dmg.sh
./Scripts/build_dmg.sh
```

Artifacts:

- `dist/Codex Profiles.app`
- `dist/Codex Profiles.dmg`
