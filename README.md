# claude-nix-sandbox

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox, with no access to your home directory, while keeping `nix build` usable as a normal user.

Inside the sandbox, Claude only sees the project directory you start it from. Your SSH keys, dotfiles, browser profiles and other projects stay out of reach.

## Quick start

```sh
cd ~/code/my-project
nix run github:nixcloud/claude-nix-sandbox
```

Or install it permanently:

```sh
nix profile add github:nixcloud/claude-nix-sandbox
cd ~/code/my-project
claude-nix-sandbox
```

On older Nix versions without `nix profile add`, use `nix profile install` instead.

Run without arguments, `claude-nix-sandbox` continues the most recent session for the current directory (`claude --continue`), so after a reboot or crash you're back where you left off. If the directory has no session yet, a new one starts.

To start a fresh session instead:

```sh
claude-nix-sandbox --new
```

Any other arguments are passed through to `claude` unchanged. For example, `claude-nix-sandbox --resume` opens the session picker.

To open a Bash shell inside the same sandbox, for debugging or one-time setup:

```sh
claude-nix-sandbox --shell
```

## What the sandbox can see

| Path | Access |
|---|---|
| Current directory (`$PWD`) | read-write, mounted at its real path |
| Sandbox home (`/home/sandbox`) | read-write, persistent (see below) |
| `/nix` | read-only |
| `/nix/var/nix/daemon-socket` | read-write, used to talk to the Nix daemon |
| `/etc/{nix,static,resolv.conf,hosts,nsswitch.conf,passwd,group,localtime}` | read-only |
| `/tmp` | private tmpfs, discarded on exit |
| Everything else under `/` | **read-only** |
| Network | shared, because Claude needs the API |
| Your real `$HOME` | **not visible** |

The sandbox root is remounted read-only after all mounts are set up. A write outside the project, the sandbox home or `/tmp` (for example to `/home/you/other-dir`) fails with `Read-only file system` instead of silently landing in memory and being lost on exit.

All other namespaces (PID, IPC, UTS, user and cgroup) are unshared. The environment is cleared, and `PATH` contains only a curated tool set: coreutils, git, ripgrep, fd, jq, curl, nix and similar.

As a safety check, `claude-nix-sandbox` refuses to start when the current directory is `/`, your home directory, or a parent of it.

## Using Nix inside the sandbox

`nix` runs with `NIX_REMOTE=daemon`, so builds are performed by the host's Nix daemon:

```sh
nix build            # creates ./result as usual
nix develop
nix shell nixpkgs#hello
```

Flakes and `nix-command` are enabled through `NIX_CONFIG`. Your system's `/etc/nix/nix.conf`, including substituters, is respected.

If Claude needs a tool that isn't in the default set, it can use `nix shell nixpkgs#<tool>` or the project's own dev shell.

## Persistent state

The sandbox has its own home directory, which holds the Claude login, `~/.claude`, `~/.claude.json`, the Nix eval cache and git config. Its location is:

```
${CLAUDE_NIX_SANDBOX_HOME:-${XDG_STATE_HOME:-~/.local/state}/claude-nix-sandbox/home}
```

The tool used to be called `claude-sandbox`. If `~/.local/state/claude-sandbox` exists and `~/.local/state/claude-nix-sandbox` doesn't, the old directory is moved over once on first start, so your login and sessions are kept. The environment variables were renamed from `CLAUDE_SANDBOX_*` to `CLAUDE_NIX_SANDBOX_*`.

Sessions are stored per project directory under `.claude/projects/` in the sandbox home. Automatic continuing only finds sessions created with the same sandbox home. Sessions from the host's `claude` or from a different `CLAUDE_NIX_SANDBOX_HOME` are not visible.

To give a project its own isolated state, set `CLAUDE_NIX_SANDBOX_HOME`:

```sh
CLAUDE_NIX_SANDBOX_HOME=~/.local/state/claude-nix-sandbox/work claude-nix-sandbox
```

On first start, log in to Claude as usual. Git has no identity inside the sandbox, so set one once:

```sh
claude-nix-sandbox --shell
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

## Updates

Each time it starts, `claude-nix-sandbox` compares the Git revision it was built from with the latest commit on `github:nixcloud/claude-nix-sandbox`. The check runs on the host before the sandbox starts, so Claude never sees it. If a newer version exists, you are asked:

```
claude-nix-sandbox: new version available (dde06bf → 1a2b3c4).
Update now (nix profile add github:nixcloud/claude-nix-sandbox)? [y/N]
```

If you answer `y`, the existing profile entry is upgraded with `nix profile upgrade --refresh`. Without one, it is installed with `nix profile add --refresh github:nixcloud/claude-nix-sandbox` (`nix profile install` on Nix versions without `add`). The new version then starts right away with the same arguments. Any other answer starts the installed version.

The check is skipped when:

- stdin or stdout is not a terminal,
- the build has no Git revision (local builds with uncommitted changes),
- `nix` is not on the host's `PATH`,
- GitHub can't be reached within 3 seconds,
- `CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1` is set.

## Requirements

- Linux (`x86_64-linux` or `aarch64-linux`)
- A **multi-user Nix installation** with a running daemon. This is the default on NixOS and with the official and Determinate installers.
- Unprivileged user namespaces enabled. This is the default on NixOS. On Ubuntu 24.04 and later, AppArmor may restrict them for unconfined binaries.
- `claude-code` is unfree. The flake allows exactly this one unfree package, so you don't need to change your global config.

## Limitations

- **The network is open.** The sandbox protects your files but does not restrict network access. Anything in the project directory can be sent out.
- **No SSH keys or credential helpers**, so `git push` over SSH won't work from inside. Push from the host instead.
- **Git worktrees and submodules** whose `.git` points outside the project directory won't resolve.
- **The Nix daemon is shared.** Builds run with the daemon's privileges, as with any `nix build`. The sandbox cannot add new trusted users or substituters unless your `nix.conf` allows it.
- Claude Code's auto-updater is disabled (`DISABLE_AUTOUPDATER=1`). Claude Code is updated together with `claude-nix-sandbox` (see [Updates](#updates)).

## How it works

`claude-nix-sandbox` is a `writeShellApplication` wrapper around `bwrap`. Everything is in [`flake.nix`](./flake.nix). It is short and meant to be read and adapted.

