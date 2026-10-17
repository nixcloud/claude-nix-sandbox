# claude-sandbox

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox, with no access to your home directory, while keeping `nix build` usable as a normal user.

Inside the sandbox, Claude only sees the project directory you start it from. Your SSH keys, dotfiles, browser profiles and other projects stay out of reach.

## Quick start

```sh
cd ~/code/my-project
nix run github:qknight/claude-sandbox
```

Or install it permanently:

```sh
nix profile install github:qknight/claude-sandbox
cd ~/code/my-project
claude-sandbox
```

Arguments are passed through to `claude`. For example, `claude-sandbox --resume` resumes a session.

To open a Bash shell inside the same sandbox, for debugging or one-time setup:

```sh
claude-sandbox --shell
```

## What the sandbox can see

| Path | Access |
|---|---|
| Current directory (`$PWD`) | read-write, mounted at its real path |
| Sandbox home (`/home/sandbox`) | read-write, persistent (see below) |
| `/nix` | read-only |
| `/nix/var/nix/daemon-socket` | read-write, used to talk to the Nix daemon |
| `/etc/{nix,static,resolv.conf,hosts,nsswitch.conf,passwd,group,localtime}` | read-only |
| `/tmp` | private tmpfs |
| Network | shared, because Claude needs the API |
| Your real `$HOME` | **not visible** |

All other namespaces (PID, IPC, UTS, user and cgroup) are unshared. The environment is cleared, and `PATH` contains only a curated tool set: coreutils, git, ripgrep, fd, jq, curl, nix and similar.

As a safety check, `claude-sandbox` refuses to start when the current directory is `/`, your home directory, or a parent of it.

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
${CLAUDE_SANDBOX_HOME:-${XDG_STATE_HOME:-~/.local/state}/claude-sandbox/home}
```

To give a project its own isolated state, set `CLAUDE_SANDBOX_HOME`:

```sh
CLAUDE_SANDBOX_HOME=~/.local/state/claude-sandbox/work claude-sandbox
```

On first start, log in to Claude as usual. Git has no identity inside the sandbox, so set one once:

```sh
claude-sandbox --shell
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

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
- Claude Code's auto-updater is disabled (`DISABLE_AUTOUPDATER=1`). Update with `nix flake update`, or `nix profile upgrade` if you installed it that way.

## How it works

`claude-sandbox` is a `writeShellApplication` wrapper around `bwrap`. Everything is in [`flake.nix`](./flake.nix). It is short and meant to be read and adapted.

