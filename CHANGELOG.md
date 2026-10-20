# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Renamed `claude-sandbox` to `claude-nix-sandbox`.** This covers the command, the flake package (`packages.<system>.claude-nix-sandbox`), the tool environment (`claude-nix-sandbox-tools`) and all messages.
- **Renamed the environment variables:** `CLAUDE_SANDBOX_HOME` is now `CLAUDE_NIX_SANDBOX_HOME`, and `CLAUDE_SANDBOX_NO_UPDATE_CHECK` is now `CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK`. The old names are no longer read.
- **Moved the state directory** from `~/.local/state/claude-sandbox` to `~/.local/state/claude-nix-sandbox`. On first start, an existing old directory is moved over once, so the login and sessions are kept.
- **Running without arguments now continues the project's most recent session** (`claude --continue`), so work picks up after a reboot or crash. If there is no previous session, a new one starts.
- **All messages and prompts are now in English** (they were German), e.g. the update prompt now reads `new version available (…)` / `Update now (…)? [y/N]`.
- **The README now uses `nix profile add`** as the install command. On older Nix versions, `nix profile install` still works.

### Added

- **`--new` flag** to start a fresh session instead of continuing the last one.
- **Update check on every start.** The check runs on the host before the sandbox starts. If GitHub has a newer commit, it asks whether to update, then upgrades the existing profile entry or installs one (`nix profile add`, falling back to `nix profile install` on older Nix) and restarts the new version.
  - Skipped when stdin or stdout is not a terminal, when the build has no Git revision, when GitHub doesn't answer within 3 seconds, or when `CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1` is set.

### Fixed

- **Starting without arguments printed `compgen: command not found`.** The check for a previous session to continue used a Bash builtin that the launcher's Bash doesn't have, so the last session was never continued. The check now works and the error is gone.
- **Writes outside the project directory were silently lost.** The sandbox root was a writable in-memory tmpfs, so a write to a path like `/home/you/other-dir` seemed to succeed but disappeared on exit. The root is now remounted read-only, and such writes fail with `Read-only file system`. The project, the sandbox home and `/tmp` stay writable.
