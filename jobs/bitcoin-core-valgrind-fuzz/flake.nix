{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.gcc = pkgs.mkShell {
        packages = with pkgs; [
          ccache
          cmake
          gcc
          ninja
          pkg-config
          python3
          valgrind
        ];

        buildInputs = with pkgs; [
          boost
          capnproto
          libevent
          openssl
          sqlite
          zlib
        ];
      };
    };
}
