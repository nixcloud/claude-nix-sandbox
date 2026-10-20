{
  description = "Claude Code in a bubblewrap sandbox, without access to your home directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          # claude-code is unfree; allow only this one package
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
        }));
    in
    {
      packages = forAllSystems (pkgs:
        let
          # Tools on the PATH inside the sandbox
          tools = pkgs.buildEnv {
            name = "claude-nix-sandbox-tools";
            paths = with pkgs; [
              claude-code
              bashInteractive
              coreutils
              findutils
              gnugrep
              gnused
              gawk
              diffutils
              patch
              which
              file
              less
              procps
              gnutar
              gzip
              xz
              bzip2
              unzip
              ripgrep
              fd
              jq
              curl
              git
              nix # client only; talks to the host's Nix daemon
            ];
          };

          caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          # Git revision of this build (empty for local builds with uncommitted changes)
          rev = self.rev or "";

          claude-nix-sandbox = pkgs.writeShellApplication {
            name = "claude-nix-sandbox";
            runtimeInputs = [ pkgs.bubblewrap pkgs.coreutils pkgs.git pkgs.jq ];
            text = ''
              # Update check on the host, before the sandbox starts
              # (disable with CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1)
              repo_url="https://github.com/nixcloud/claude-nix-sandbox"
              flake_ref="github:nixcloud/claude-nix-sandbox"
              installed_rev="${rev}"

              update_sandbox() {
                # Upgrade the existing profile entry, otherwise install a new one
                local element
                element="$(nix profile list --json 2>/dev/null \
                  | jq -r --arg u "$flake_ref" \
                      '.elements | to_entries[] | select((.value.originalUrl // "") | startswith($u)) | .key' \
                  | head -n1 || true)"
                if [ -n "$element" ]; then
                  nix profile upgrade --refresh "$element"
                else
                  nix profile "$(profile_add_cmd)" --refresh "$flake_ref"
                fi
              }

              # Newer Nix versions renamed "nix profile install" to "nix profile add"
              profile_add_cmd() {
                if nix profile add --help >/dev/null 2>&1; then
                  echo add
                else
                  echo install
                fi
              }

              if [ -z "''${CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK:-}" ] && [ -n "$installed_rev" ] \
                 && [ -t 0 ] && [ -t 1 ] && command -v nix >/dev/null; then
                latest_rev="$(GIT_TERMINAL_PROMPT=0 timeout 3 git ls-remote "$repo_url" HEAD 2>/dev/null | cut -f1 || true)"
                if [ -n "$latest_rev" ] && [ "$latest_rev" != "$installed_rev" ]; then
                  echo "claude-nix-sandbox: new version available (''${installed_rev:0:7} → ''${latest_rev:0:7})." >&2
                  read -r -p "Update now (nix profile $(profile_add_cmd) $flake_ref)? [y/N] " answer
                  case "$answer" in
                    [yYjJ]*)
                      if update_sandbox; then
                        # Start the new version without checking again
                        export CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1
                        if new_bin="$(command -v claude-nix-sandbox)"; then
                          exec "$new_bin" "$@"
                        fi
                      else
                        echo "claude-nix-sandbox: update failed, starting the installed version." >&2
                      fi
                      ;;
                  esac
                fi
              fi

              project="$(pwd -P)"
              home_real="$(cd "$HOME" && pwd -P)"

              # Safety: never expose the home directory (or one of its parents)
              if [ "$project" = "/" ]; then
                echo "claude-nix-sandbox: '/' cannot be used as the project directory." >&2
                exit 1
              fi
              case "$home_real/" in
                "$project"/*)
                  echo "claude-nix-sandbox: $project is or contains your home directory, aborting." >&2
                  exit 1
                  ;;
              esac

              # Separate, persistent home for the sandbox (login, ~/.claude, Nix cache, ...)
              state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}"
              sandbox_home="''${CLAUDE_NIX_SANDBOX_HOME:-$state_dir/claude-nix-sandbox/home}"

              # One-time migration from the old name "claude-sandbox" (login, sessions)
              if [ -z "''${CLAUDE_NIX_SANDBOX_HOME:-}" ] && [ ! -e "$state_dir/claude-nix-sandbox" ] \
                 && [ -d "$state_dir/claude-sandbox" ]; then
                mv "$state_dir/claude-sandbox" "$state_dir/claude-nix-sandbox"
                echo "claude-nix-sandbox: moved state over from $state_dir/claude-sandbox." >&2
              fi
              mkdir -p "$sandbox_home"

              bwrap_args=(
                --unshare-all
                --share-net
                --die-with-parent
                --clearenv

                --proc /proc
                --dev /dev
                --tmpfs /tmp

                # Nix store read-only, daemon socket for "nix build" as a normal user
                --ro-bind /nix /nix
                --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket

                # Minimal parts of /etc (DNS, users, Nix configuration)
                --ro-bind-try /etc/static /etc/static
                --ro-bind-try /etc/nix /etc/nix
                --ro-bind-try /etc/resolv.conf /etc/resolv.conf
                --ro-bind-try /etc/hosts /etc/hosts
                --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
                --ro-bind-try /etc/passwd /etc/passwd
                --ro-bind-try /etc/group /etc/group
                --ro-bind-try /etc/localtime /etc/localtime

                # Common paths that scripts expect
                --dir /usr/bin
                --symlink ${tools}/bin/env /usr/bin/env
                --dir /bin
                --symlink ${pkgs.bashInteractive}/bin/sh /bin/sh

                # Sandbox home and project
                --bind "$sandbox_home" /home/sandbox
                --bind "$project" "$project"
                --chdir "$project"

                --setenv HOME /home/sandbox
                --setenv USER "$(id -un)"
                --setenv PATH ${tools}/bin
                --setenv SHELL ${pkgs.bashInteractive}/bin/bash
                --setenv TERM "''${TERM:-xterm-256color}"
                --setenv LANG C.UTF-8
                --setenv TMPDIR /tmp
                --setenv NIX_REMOTE daemon
                --setenv NIX_CONFIG "experimental-features = nix-command flakes"
                --setenv SSL_CERT_FILE ${caBundle}
                --setenv NIX_SSL_CERT_FILE ${caBundle}
                --setenv DISABLE_AUTOUPDATER 1

                # Make the root tmpfs read-only (must come after all mounts):
                # writes outside the project, /home/sandbox and /tmp fail
                --remount-ro /
              )

              if [ -n "''${COLORTERM:-}" ]; then
                bwrap_args+=(--setenv COLORTERM "$COLORTERM")
              fi

              # "claude-nix-sandbox --shell" opens a Bash shell in the sandbox (for testing)
              # Without arguments: continue this project's last session, if there is one
              # ("claude-nix-sandbox --new" forces a new session)
              session_dir="$sandbox_home/.claude/projects/''${project//[^a-zA-Z0-9]/-}"
              # compgen is missing from the non-interactive bash used here
              has_session() {
                local f
                for f in "$session_dir"/*.jsonl; do
                  [ -e "$f" ] && return 0
                done
                return 1
              }
              if [ "''${1:-}" = "--shell" ]; then
                shift
                cmd=(${pkgs.bashInteractive}/bin/bash "$@")
              elif [ "''${1:-}" = "--new" ]; then
                shift
                cmd=(${pkgs.claude-code}/bin/claude "$@")
              elif [ $# -eq 0 ] && has_session; then
                cmd=(${pkgs.claude-code}/bin/claude --continue)
              else
                cmd=(${pkgs.claude-code}/bin/claude "$@")
              fi

              exec bwrap "''${bwrap_args[@]}" "''${cmd[@]}"
            '';
          };
        in
        {
          inherit claude-nix-sandbox;
          default = claude-nix-sandbox;
        });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/claude-nix-sandbox";
        };
      });
    };
}
