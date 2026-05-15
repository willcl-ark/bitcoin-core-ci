{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      llvm = pkgs.llvmPackages_latest;
      cmake = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "kitware-cmake-bin";
        version = "4.3.2";

        src = pkgs.fetchurl {
          url = "https://github.com/Kitware/CMake/releases/download/v${version}/cmake-${version}-linux-x86_64.tar.gz";
          hash = "sha256-eRrjYEhBygPLOImjrYkWU0bksYCuNEjv1LDKqe9G0kU=";
        };

        sourceRoot = "cmake-${version}-linux-x86_64";
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.glibc ];

        installPhase = ''
          runHook preInstall

          mkdir -p "$out"
          cp -R . "$out"
          rm -f "$out/bin/cmake-gui"
          rm -rf "$out/doc"

          runHook postInstall
        '';
      };
      commonNativeBuildInputs = [
        pkgs.bison
        pkgs.ccache
        pkgs.clang-tools
        cmake
        pkgs.curlMinimal
        pkgs.libsystemtap
        pkgs.linuxPackages.bcc
        pkgs.linuxPackages.bpftrace
        pkgs.ninja
        pkgs.pkg-config
        pkgs.xz
      ];
      commonBuildInputs = [
        pkgs.boost
        pkgs.capnproto
        pkgs.libevent
        pkgs.sqlite.dev
        pkgs.zeromq
      ];
    in
    {
      devShells.${system} = {
        gcc = pkgs.mkShell {
          nativeBuildInputs = commonNativeBuildInputs ++ [
            pkgs.gcc_latest
          ];

          buildInputs = commonBuildInputs;
        };

        libcxx = pkgs.mkShell.override { stdenv = llvm.libcxxStdenv; } {
          nativeBuildInputs = commonNativeBuildInputs ++ [
            llvm.libcxxClang
          ];

          buildInputs = commonBuildInputs;

          shellHook = ''
            export CC=clang
            export CXX=clang++
          '';
        };
      };
    };
}
