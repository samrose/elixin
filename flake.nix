# flake.nix
{
  description = "Build system with Elixir orchestration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Import the build system (assuming it's in ./lib/build-system.nix)
        buildSystem = import ./lib/build-system.nix {
          inherit (pkgs) lib stdenv elixir writeText writeScript;
        };
        
        # Example project build
        exampleProject = buildSystem.mkCachedBuild {
          name = "my-project";
          steps = {
            configure = {
              command = "./configure";
              inputs = ["configure.ac"];
              outputs = ["Makefile"];
            };
            
            build = {
              command = "make -j$NIX_BUILD_CORES";
              inputs = [
                "src/**/*.c"
                "src/**/*.h"
                "Makefile"
              ];
              outputs = ["bin/*"];
              env = {
                CFLAGS = "-O3";
              };
            };
            
            test = {
              command = "make test";
              inputs = [
                "tests/**/*"
                "bin/*"
              ];
              outputs = ["test-results/*"];
            };
          };
        };
        
      in {
        # Expose the build system as a library
        lib = {
          inherit (buildSystem) mkCachedBuild;
        };
        
        # Example package using the build system
        packages = {
          example = exampleProject;
          default = exampleProject;
        };
        
        # Development shell with required tools
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            elixir
          ];
        };
      }
    );
}