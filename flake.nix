{
  description = "A package manager for the Zig programming language.";
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-22.05;
    zig.url     = github:mitchellh/zig-overlay;
    utils.url   = github:numtide/flake-utils;

    # Used for shell.nix
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
  };

  outputs = {self, nixpkgs, zig, utils, ...} @ inputs: with utils.lib;
    eachSystem allSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            zigpkgs = inputs.zig.packages.${prev.system};
          })
        ];
      };

      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames inputs.zig.packages;

      pname = "gyro";
      version = "0.7.0";

      gyro = pkgs.stdenv.mkDerivation {
        inherit pname version;
        src = ./.;
        nativeBuildInputs = with pkgs; [
          git
          mercurial
          wget
          unzip
          gnutar
          zigpkgs.master
          pkg-config
        ];
        buildInputs = with pkgs; [ ];
        dontConfigure = true;
        preBuild = ''
          export HOME=$TMPDIR
        '';

        installPhase = ''
          runHook preInstall
          zig build -Drelease-safe
          runHook postInstall
        '';

        installFlags = ["DESTDIR=$(out)"];

        meta = {
          maintainers = [ "Jake Chvatal <jake@isnt.online>" ];
          description = "gyro";
        };
      };

    in rec {
      packages = {
        gyro = gyro;
        default = gyro;
      };

      defaultPackage = gyro;

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          zigpkgs.master
        ];

        buildInputs = with pkgs; [
          git
          mercurial
          wget
          unzip
          gnutar
        ];
      };

      devShell = self.devShells.${system}.default;
    });
}
