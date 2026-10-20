{
  description = "Claude Code in einer bubblewrap-Sandbox – ohne Zugriff auf das Home-Verzeichnis";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          # claude-code ist unfree – nur dieses eine Paket freigeben
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
        }));
    in
    {
      packages = forAllSystems (pkgs:
        let
          # Werkzeuge, die innerhalb der Sandbox im PATH liegen
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
              nix # Client – spricht mit dem Nix-Daemon des Hosts
            ];
          };

          caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          # Git-Revision dieses Builds (leer bei lokalen, ungesicherten Änderungen)
          rev = self.rev or "";

          claude-nix-sandbox = pkgs.writeShellApplication {
            name = "claude-nix-sandbox";
            runtimeInputs = [ pkgs.bubblewrap pkgs.coreutils pkgs.git pkgs.jq ];
            text = ''
              # Update-Check auf dem Host, bevor die Sandbox startet
              # (abschalten mit CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1)
              repo_url="https://github.com/nixcloud/claude-nix-sandbox"
              flake_ref="github:nixcloud/claude-nix-sandbox"
              installed_rev="${rev}"

              update_sandbox() {
                # Vorhandenen Profil-Eintrag aktualisieren, sonst neu installieren
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

              # Neuere Nix-Versionen nennen "nix profile install" jetzt "nix profile add"
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
                  echo "claude-nix-sandbox: neue Version verfügbar (''${installed_rev:0:7} → ''${latest_rev:0:7})." >&2
                  read -r -p "Jetzt aktualisieren (nix profile $(profile_add_cmd) $flake_ref)? [y/N] " answer
                  case "$answer" in
                    [yYjJ]*)
                      if update_sandbox; then
                        # Neue Version starten, ohne erneut zu prüfen
                        export CLAUDE_NIX_SANDBOX_NO_UPDATE_CHECK=1
                        if new_bin="$(command -v claude-nix-sandbox)"; then
                          exec "$new_bin" "$@"
                        fi
                      else
                        echo "claude-nix-sandbox: Update fehlgeschlagen – starte die installierte Version." >&2
                      fi
                      ;;
                  esac
                fi
              fi

              project="$(pwd -P)"
              home_real="$(cd "$HOME" && pwd -P)"

              # Schutz: niemals das Home-Verzeichnis (oder ein Elternverzeichnis davon) freigeben
              if [ "$project" = "/" ]; then
                echo "claude-nix-sandbox: '/' kann nicht als Projektverzeichnis verwendet werden." >&2
                exit 1
              fi
              case "$home_real/" in
                "$project"/*)
                  echo "claude-nix-sandbox: $project ist dein Home oder enthält es – abgebrochen." >&2
                  exit 1
                  ;;
              esac

              # Separates, persistentes Home für die Sandbox (Login, ~/.claude, Nix-Cache …)
              state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}"
              sandbox_home="''${CLAUDE_NIX_SANDBOX_HOME:-$state_dir/claude-nix-sandbox/home}"

              # Einmalige Migration vom alten Namen "claude-sandbox" (Login, Sitzungen)
              if [ -z "''${CLAUDE_NIX_SANDBOX_HOME:-}" ] && [ ! -e "$state_dir/claude-nix-sandbox" ] \
                 && [ -d "$state_dir/claude-sandbox" ]; then
                mv "$state_dir/claude-sandbox" "$state_dir/claude-nix-sandbox"
                echo "claude-nix-sandbox: Zustand von $state_dir/claude-sandbox übernommen." >&2
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

                # Nix-Store nur lesend, Daemon-Socket für "nix build" als normaler Nutzer
                --ro-bind /nix /nix
                --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket

                # Minimal nötige Teile von /etc (DNS, Nutzer, Nix-Konfiguration)
                --ro-bind-try /etc/static /etc/static
                --ro-bind-try /etc/nix /etc/nix
                --ro-bind-try /etc/resolv.conf /etc/resolv.conf
                --ro-bind-try /etc/hosts /etc/hosts
                --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
                --ro-bind-try /etc/passwd /etc/passwd
                --ro-bind-try /etc/group /etc/group
                --ro-bind-try /etc/localtime /etc/localtime

                # Übliche Pfade, die Skripte erwarten
                --dir /usr/bin
                --symlink ${tools}/bin/env /usr/bin/env
                --dir /bin
                --symlink ${pkgs.bashInteractive}/bin/sh /bin/sh

                # Sandbox-Home und Projekt
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

                # Root-tmpfs schreibgeschützt machen (muss nach allen Mounts kommen):
                # Schreibzugriffe außerhalb von Projekt, /home/sandbox und /tmp schlagen fehl
                --remount-ro /
              )

              if [ -n "''${COLORTERM:-}" ]; then
                bwrap_args+=(--setenv COLORTERM "$COLORTERM")
              fi

              # "claude-nix-sandbox --shell" öffnet eine Bash in der Sandbox (zum Testen)
              # Ohne Argumente: letzte Sitzung dieses Projekts fortsetzen, falls vorhanden
              # ("claude-nix-sandbox --new" erzwingt eine neue Sitzung)
              session_dir="$sandbox_home/.claude/projects/''${project//[^a-zA-Z0-9]/-}"
              if [ "''${1:-}" = "--shell" ]; then
                shift
                cmd=(${pkgs.bashInteractive}/bin/bash "$@")
              elif [ "''${1:-}" = "--new" ]; then
                shift
                cmd=(${pkgs.claude-code}/bin/claude "$@")
              elif [ $# -eq 0 ] && compgen -G "$session_dir/*.jsonl" >/dev/null; then
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
