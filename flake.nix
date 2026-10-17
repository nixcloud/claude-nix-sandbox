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
            name = "claude-sandbox-tools";
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

          claude-sandbox = pkgs.writeShellApplication {
            name = "claude-sandbox";
            runtimeInputs = [ pkgs.bubblewrap pkgs.coreutils ];
            text = ''
              project="$(pwd -P)"
              home_real="$(cd "$HOME" && pwd -P)"

              # Schutz: niemals das Home-Verzeichnis (oder ein Elternverzeichnis davon) freigeben
              if [ "$project" = "/" ]; then
                echo "claude-sandbox: '/' kann nicht als Projektverzeichnis verwendet werden." >&2
                exit 1
              fi
              case "$home_real/" in
                "$project"/*)
                  echo "claude-sandbox: $project ist dein Home oder enthält es – abgebrochen." >&2
                  exit 1
                  ;;
              esac

              # Separates, persistentes Home für die Sandbox (Login, ~/.claude, Nix-Cache …)
              sandbox_home="''${CLAUDE_SANDBOX_HOME:-''${XDG_STATE_HOME:-$HOME/.local/state}/claude-sandbox/home}"
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
              )

              if [ -n "''${COLORTERM:-}" ]; then
                bwrap_args+=(--setenv COLORTERM "$COLORTERM")
              fi

              # "claude-sandbox --shell" öffnet eine Bash in der Sandbox (zum Testen)
              if [ "''${1:-}" = "--shell" ]; then
                shift
                cmd=(${pkgs.bashInteractive}/bin/bash "$@")
              else
                cmd=(${pkgs.claude-code}/bin/claude "$@")
              fi

              exec bwrap "''${bwrap_args[@]}" "''${cmd[@]}"
            '';
          };
        in
        {
          inherit claude-sandbox;
          default = claude-sandbox;
        });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/claude-sandbox";
        };
      });
    };
}
