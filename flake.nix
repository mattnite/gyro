{
  description = "A Zig package manager with an index, build runner, and build dependencies.";
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
            # zig = inputs.zig.packages.${zigVersion}.${prev.system};
          })
        ];
      };

      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames inputs.zig.packages;

      pname = "gyro";
      version = "0.7.0";

      zigVersion = "0.10.0";
      z = pkgs.zigpkgs.${zigVersion};

      gyro = pkgs.stdenv.mkDerivation {
        inherit pname version;
        src = ./.;
        nativeBuildInputs = with pkgs; [ z ];
        buildInputs = with pkgs; [ ];
        dontConfigure = true;

        preBuild = ''
          export HOME=$TMPDIR
        '';

        installPhase = ''
          runHook preInstall
          zig build -Drelease-safe --prefix $out install
          runHook postInstall
        '';

        installFlags = ["DESTDIR=$(out)"];

        meta = with pkgs.lib; {
          description = "A Zig package manager with an index, build runner, and build dependencies.";
          license = licenses.mit;
          platforms = platforms.linux;
          maintainers = with maintainers; [ jakeisnt ];
        };
      };

    in rec {
      packages = {
        gyro = gyro;
        default = gyro;
      };

      defaultPackage = gyro;

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [ ];
        buildInputs = with pkgs; [ z gyro ];
      };

      devShell = self.devShells.${system}.default;
    });
}
