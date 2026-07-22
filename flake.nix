{
  description = "Home CI lab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bitcoin-core-nightly = {
      url = "path:./jobs/bitcoin-core-nightly";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    bitcoin-core-bench = {
      url = "path:./jobs/bitcoin-core-bench";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    bitcoin-core-guix = {
      url = "path:./jobs/bitcoin-core-guix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    bitcoin-core-valgrind-fuzz = {
      url = "path:./jobs/bitcoin-core-valgrind-fuzz";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      bitcoin-core-nightly,
      bitcoin-core-bench,
      bitcoin-core-guix,
      bitcoin-core-valgrind-fuzz,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-tree;

      devShells.${system} = {
        bitcoin-core-nightly-gcc = bitcoin-core-nightly.devShells.${system}.gcc;
        bitcoin-core-nightly-libcxx = bitcoin-core-nightly.devShells.${system}.libcxx;
        bitcoin-core-bench-gcc = bitcoin-core-bench.devShells.${system}.gcc;
        bitcoin-core-guix = bitcoin-core-guix.devShells.${system}.default;
        bitcoin-core-valgrind-fuzz-gcc = bitcoin-core-valgrind-fuzz.devShells.${system}.gcc;
      };

      nixosConfigurations.beelink = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./machines/beelink/hardware-configuration.nix
          (
            { lib, pkgs, ... }:
            {
              imports = [
                sops-nix.nixosModules.sops
              ];
            }
          )
          (
            {
              lib,
              pkgs,
              config,
              ...
            }:
            let
              ciHome = "/var/lib/ci-runner";
              ccacheDir = "/var/cache/ci-runner/ccache";
              workDir = "${ciHome}/work";
              queueDir = "${ciHome}/queue";
              runnerConfig = pkgs.writeText "ci-runner-jobs.json" (
                builtins.toJSON {
                  jobs = config.ci.runner.jobs;
                }
              );
              ciRunner = pkgs.writeTextFile {
                name = "ci-runner";
                executable = true;
                destination = "/bin/ci-runner";
                text = "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./runner/ci_runner.py;
              };
              ctestSite = "willcl-ark/beelink";
              cdashBuildNamePrefix = "nixpkgs";
            in
            {
              imports = [
                ./jobs/bitcoin-core-nightly/module.nix
                ./jobs/bitcoin-core-bench/module.nix
                ./jobs/bitcoin-core-guix/module.nix
                ./jobs/bitcoin-core-valgrind-fuzz/module.nix
              ];

              options.ci.runner.jobs = lib.mkOption {
                type = lib.types.attrs;
                default = { };
                description = "CI queue runner job definitions.";
              };

              config = {
                _module.args = {
                  inherit ciRunner system;
                  ci = {
                    home = ciHome;
                    queueDir = queueDir;
                    workDir = workDir;
                    flake = self.outPath;
                    bitcoinRepoUrl = "https://github.com/bitcoin/bitcoin";
                    ctestSite = ctestSite;
                    cdashBuildNamePrefix = cdashBuildNamePrefix;
                    ccache = {
                      dir = ccacheDir;
                      maxSize = "75G";
                    };
                    jobs = {
                      nightly = ./jobs/bitcoin-core-nightly;
                      bench = ./jobs/bitcoin-core-bench;
                      guix = ./jobs/bitcoin-core-guix;
                      valgrindFuzz = ./jobs/bitcoin-core-valgrind-fuzz;
                    };
                  };
                };

                boot.loader.systemd-boot.enable = true;
                boot.loader.efi.canTouchEfiVariables = true;
                boot.kernelModules = [ "msr" ];

                fileSystems."/tmp" = {
                  device = "tmpfs";
                  fsType = "tmpfs";
                  options = [
                    "mode=1777"
                    "size=32G"
                  ];
                };

                networking.hostName = "beelink";
                networking.networkmanager = {
                  enable = true;
                  insertNameservers = [
                    "1.1.1.1"
                    "8.8.8.8"
                  ];
                };

                time.timeZone = "Europe/London";
                i18n.defaultLocale = "en_GB.UTF-8";

                services.openssh.enable = true;
                services.guix = {
                  enable = true;
                  package = pkgs.guix;
                };

                sops = {
                  defaultSopsFile = ./secrets/beelink.yaml;
                  age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
                };

                users.users.root.openssh.authorizedKeys.keys = [
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
                ];

                users.users.will = {
                  isNormalUser = true;
                  extraGroups = [
                    "networkmanager"
                    "wheel"
                  ];
                  openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
                  ];
                };

                users.groups.ci-runner = { };
                users.users.ci-runner = {
                  isSystemUser = true;
                  group = "ci-runner";
                  home = ciHome;
                  createHome = true;
                };

                security.sudo.wheelNeedsPassword = false;

                nix.settings = {
                  experimental-features = [
                    "nix-command"
                    "flakes"
                  ];
                  trusted-users = [
                    "root"
                    "will"
                    "ci-runner"
                  ];
                };

                hardware.enableRedistributableFirmware = true;

                environment.systemPackages = with pkgs; [
                  ciRunner
                  git
                  vim
                ];

                systemd.tmpfiles.rules = [
                  "d ${ciHome} 0750 ci-runner ci-runner -"
                  "d /var/cache/ci-runner 0750 ci-runner ci-runner -"
                  "d ${ccacheDir} 0750 ci-runner ci-runner -"
                  "d ${workDir} 0750 ci-runner ci-runner -"
                  "d ${queueDir} 0750 ci-runner ci-runner -"
                  "d ${queueDir}/pending 0750 ci-runner ci-runner -"
                  "d ${queueDir}/running 0750 ci-runner ci-runner -"
                  "d ${queueDir}/done 0750 ci-runner ci-runner -"
                  "d ${queueDir}/failed 0750 ci-runner ci-runner -"
                  "d ${queueDir}/watch 0750 ci-runner ci-runner -"
                ];

                systemd.services.ci-runner = {
                  description = "CI queue runner";
                  restartIfChanged = false;
                  wantedBy = [ "multi-user.target" ];
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [
                    bash
                    cmake
                    coreutils
                    curl
                    findutils
                    getent
                    git
                    gnumake
                    gnused
                    gnutar
                    guix
                    nix
                    python3
                    sudo
                  ];
                  serviceConfig = {
                    Type = "simple";
                    User = "ci-runner";
                    Group = "ci-runner";
                    WorkingDirectory = ciHome;
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} run --config ${runnerConfig}";
                    Restart = "always";
                    RestartSec = "10";
                  };
                };

                system.stateVersion = "25.11";
              };
            }
          )
        ];
      };
    };
}
