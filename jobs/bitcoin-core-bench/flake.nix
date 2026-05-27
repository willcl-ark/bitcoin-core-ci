{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      cmake =
        if system == "x86_64-linux" then
          pkgs.stdenvNoCC.mkDerivation rec {
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
          }
        else
          pkgs.cmakeCurses;
      cmakePackageInputs = [
        pkgs.boost
        pkgs.capnproto
        pkgs.openssl
        pkgs.zlib
      ];
      cmakePrefixPath = lib.concatStringsSep ":" [
        (lib.makeSearchPathOutput "dev" "" cmakePackageInputs)
        (lib.makeSearchPathOutput "out" "" cmakePackageInputs)
      ];
    in
    {
      devShells.${system}.gcc = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.bison
          pkgs.ccache
          cmake
          pkgs.gcc_latest
          pkgs.ninja
          pkgs.pkg-config
          pkgs.python3
          pkgs.util-linux
        ];

        buildInputs = [
          pkgs.boost
          pkgs.capnproto
          pkgs.libevent
          pkgs.openssl
          pkgs.sqlite.dev
          pkgs.zeromq
          pkgs.zlib
        ];

        shellHook = ''
          export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:''${CMAKE_PREFIX_PATH}}"
        '';
      };
    };
}
