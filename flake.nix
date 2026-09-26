{
  description = "Provision Fly.io Sprites with Nix and standalone home-manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;

    # Systems we drive Sprites *from* (your laptop, CI).
    #
    # x86_64-darwin is deliberately absent: nixpkgs 26.11 dropped support for
    # it outright, and upstream `sprite` has no hash for that platform either.
    # Intel macs need to pin nixos-26.05 instead.
    hostSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    forAllSystems = lib.genAttrs hostSystems;

    # A Sprite is a Firecracker microVM running an Ubuntu base image, so the
    # guest home is built for a Linux system. Fly.io currently runs Sprites on
    # x86_64; `scripts/provision.sh` picks the config from the guest's
    # `uname -m` so the aarch64 variant is ready if that changes.
    guestSystems = {
      sprite = "x86_64-linux";
      sprite-aarch64 = "aarch64-linux";
    };

    # `sprite` is a redistributed prebuilt binary, hence unfree. Allow exactly
    # that one package instead of blanket-enabling unfree for all of nixpkgs.
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: lib.getName pkg == "sprite";
      };

    mkSpriteHome = system:
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = {inherit inputs;};
        modules = [./home/sprite.nix];
      };
  in {
    # Applied *inside* the Sprite by scripts/bootstrap-guest.sh:
    #   nix build .#homeConfigurations.sprite.activationPackage && ./result/activate
    homeConfigurations = lib.mapAttrs (_name: mkSpriteHome) guestSystems;

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      # The Sprites CLI, straight from nixpkgs (pkgs/by-name/sp/sprite).
      # It ships the UPGRADE_CHECK=false wrapper, so it will not nag about
      # self-upgrading a read-only store path.
      inherit (pkgs) sprite;
      default = pkgs.sprite;

      provision = pkgs.writeShellApplication {
        name = "provision";
        runtimeInputs = [pkgs.sprite pkgs.gnutar pkgs.gzip pkgs.coreutils];
        text = builtins.readFile ./scripts/provision.sh;
        meta.description = "Provision a Sprite with Nix and home-manager";
      };
    });

    apps = forAllSystems (system: {
      provision = {
        type = "app";
        program = lib.getExe self.packages.${system}.provision;
        meta.description = "Provision a Sprite with Nix and home-manager";
      };
      default = self.apps.${system}.provision;
    });

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.sprite
          pkgs.jq
          pkgs.shellcheck
          home-manager.packages.${system}.home-manager
        ];
        shellHook = ''
          echo "sprite $(sprite --version 2>/dev/null || echo '(run: sprite login)')"
          echo "provision a sprite:  ./scripts/provision.sh <sprite-name>"
        '';
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
