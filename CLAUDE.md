# CLAUDE.md

## Changelog

Every change to behaviour, flags, environment variables, paths, the flake
outputs or the documented usage must be recorded in `CHANGELOG.md` in the
same piece of work. Do not wait to be asked.

- Add entries under `## [Unreleased]` in the matching section:
  `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Write one bullet per user-visible change, in English, from the user's
  point of view: what changed and what they need to do, not how it was coded.
- Point out breaking changes (renamed commands or variables, moved state)
  and say how to migrate.
- If a later change in the same session supersedes an `[Unreleased]` entry,
  edit that entry instead of adding a contradicting one.
- Pure refactors, comment changes and typo fixes need no entry.
- Never move entries out of `[Unreleased]` or invent version numbers or
  dates; releases are cut by the maintainer.
- When the README changes, check whether CHANGELOG.md needs a matching entry.
