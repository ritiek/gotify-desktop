{
  description = "Small Gotify daemon to receive messages and forward them as desktop notifications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    let
      perSystemOutputs = flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Read rust-version from Cargo.toml
        rustVersion = "1.86.0";

        rustToolchain = pkgs.rust-bin.stable.${rustVersion}.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        nativeBuildInputs = with pkgs; [
          pkg-config
          rustToolchain
        ];

        buildInputs = with pkgs; [
          openssl
          dbus
        ] ++ lib.optionals stdenv.hostPlatform.isDarwin [
          darwin.apple_sdk.frameworks.CoreFoundation
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.SystemConfiguration
        ];

        gotify-desktop = pkgs.rustPlatform.buildRustPackage {
          pname = "gotify-desktop";
          version = "1.4.1";

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          inherit nativeBuildInputs buildInputs;

          buildType = "release";

          meta = with pkgs.lib; {
            description = "Small Gotify daemon to receive messages and forward them as desktop notifications";
            homepage = "https://github.com/desbma/gotify-desktop";
            license = licenses.gpl3Only;
            maintainers = [ ];
            mainProgram = "gotify-desktop";
            platforms = platforms.unix;
          };
        };

      in
      {
        packages = {
          default = gotify-desktop;
          gotify-desktop = gotify-desktop;
        };

        devShells.default = pkgs.mkShell {
          inherit buildInputs;
          nativeBuildInputs = nativeBuildInputs ++ (with pkgs; [
            cargo-watch
            clippy
            rustfmt
          ]);

          shellHook = ''
            echo "Gotify Desktop development environment"
            echo "Rust version: ${rustVersion}"
            echo ""
            echo "Available commands:"
            echo "  cargo build         - Build the project"
            echo "  cargo run           - Run the daemon"
            echo "  cargo test          - Run tests"
            echo "  cargo clippy        - Run lints"
            echo ""
          '';
        };

        apps.default = {
          type = "app";
          program = "${gotify-desktop}/bin/gotify-desktop";
        };
      }
    );
      # Shared module options
      mkModuleOptions = { lib, pkgs, tomlFormat }: {
        enable = lib.mkEnableOption "Gotify Desktop notification daemon";

        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.system}.default;
          description = "The gotify-desktop package to use";
        };

        settings = lib.mkOption {
          type = tomlFormat.type;
          default = { };
          example = lib.literalExpression ''
            {
              gotify = {
                url = "wss://gotify.example.com";
                # Token can be a string or fetched from a command
                token = "YOUR_SECRET_TOKEN";
                # Or use: token.command = "pass show gotify/token";
                auto_delete = false;
              };
              notification = {
                min_priority = 0;
              };
              action = {
                on_msg_command = "/usr/bin/beep";
              };
            }
          '';
          description = ''
            Configuration for gotify-desktop written to
            {file}`$XDG_CONFIG_HOME/gotify-desktop/config.toml`.

            See <https://github.com/desbma/gotify-desktop> for supported values.
          '';
        };
      };
    in
    perSystemOutputs // {
      # Home Manager module for systemd user service integration
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.gotify-desktop;
          tomlFormat = pkgs.formats.toml { };
          configFile = tomlFormat.generate "config.toml" cfg.settings;

          setupScript = pkgs.writeShellScript "gotify-desktop-setup" ''
            mkdir -p ''${XDG_CONFIG_HOME:-$HOME/.config}/gotify-desktop
            ln -sf ${configFile} ''${XDG_CONFIG_HOME:-$HOME/.config}/gotify-desktop/config.toml
          '';
        in
        {
          options.services.gotify-desktop = mkModuleOptions { inherit lib pkgs tomlFormat; };

          config = lib.mkIf cfg.enable {
            systemd.user.services.gotify-desktop = {
              Unit = {
                Description = "Gotify daemon to send desktop notifications";
                PartOf = [ "graphical-session.target" ];
              };

              Service = {
                ExecStartPre = lib.mkIf (cfg.settings != { }) "${setupScript}";
                ExecStart = "${cfg.package}/bin/gotify-desktop";
                Restart = "always";
                RestartSec = "5s";
              };

              Install = {
                WantedBy = [ "graphical-session.target" ];
              };
            };
          };
        };

      # NixOS module for systemd service integration
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.gotify-desktop;
          tomlFormat = pkgs.formats.toml { };
          configFile = tomlFormat.generate "config.toml" cfg.settings;
        in
        {
          options.services.gotify-desktop = mkModuleOptions { inherit lib pkgs tomlFormat; };

          config = lib.mkIf cfg.enable {
            systemd.user.services.gotify-desktop = {
              description = "Gotify daemon to send desktop notifications";
              partOf = [ "graphical-session.target" ];
              wantedBy = [ "graphical-session.target" ];

              preStart = lib.mkIf (cfg.settings != { }) ''
                mkdir -p ''${XDG_CONFIG_HOME:-$HOME/.config}/gotify-desktop
                ln -sf ${configFile} ''${XDG_CONFIG_HOME:-$HOME/.config}/gotify-desktop/config.toml
              '';

              serviceConfig = {
                ExecStart = "${cfg.package}/bin/gotify-desktop";
                Restart = "always";
                RestartSec = "5s";
              };
            };
          };
        };
    };
}
