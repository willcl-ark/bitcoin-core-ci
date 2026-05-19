{
  description = "Home CI lab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

      nixosConfigurations.beelink = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./machines/beelink/hardware-configuration.nix
          (
            { lib, pkgs, ... }:
            let
              ciHome = "/var/lib/ci-runner";
              nightlyJob = ./jobs/bitcoin-core-nightly;
              guixJob = ./jobs/bitcoin-core-guix;
              valgrindFuzzJob = ./jobs/bitcoin-core-valgrind-fuzz;
              bitcoinRepo = "${ciHome}/bitcoin";
              guixBitcoinRepo = "${ciHome}/bitcoin-guix";
              valgrindFuzzBitcoinRepo = "${ciHome}/bitcoin-valgrind-fuzz";
              bitcoinRepoUrl = "https://github.com/bitcoin/bitcoin";
              qaAssetsRepoUrl = "https://github.com/bitcoin-core/qa-assets";
              ccacheDir = "/var/cache/ci-runner/ccache";
              ccacheMaxSize = "75G";
              guixSdkDir = "${ciHome}/guix-sdk";
              guixSourcesDir = "${ciHome}/guix-sources";
              guixCacheDir = "/var/cache/ci-runner/guix";
              qaAssetsDir = "${ciHome}/qa-assets";
              valgrindFuzzBuildDir = "${ciHome}/valgrind-fuzz-build";
              workDir = "${ciHome}/work";
              queueDir = "${ciHome}/queue";
              runnerConfig = pkgs.writeText "ci-runner-jobs.json" (
                builtins.toJSON {
                  jobs = {
                    bitcoin-nightly = {
                      command = [
                        "${pkgs.bash}/bin/bash"
                        "${nightlyJob}/scripts/run-nightly.sh"
                      ];
                      cwd = "${nightlyJob}";
                      env = {
                        BITCOIN_REPO = bitcoinRepo;
                        BITCOIN_REPO_URL = bitcoinRepoUrl;
                        CCACHE_DIR = ccacheDir;
                        CCACHE_MAXSIZE = ccacheMaxSize;
                        CDASH_BUILD_NAME_PREFIX = cdashBuildNamePrefix;
                        CTEST_SITE = ctestSite;
                        WORK_DIR = workDir;
                      };
                    };
                    bitcoin-guix = {
                      command = [
                        "${pkgs.bash}/bin/bash"
                        "${guixJob}/scripts/run-guix.sh"
                      ];
                      cwd = "${guixJob}";
                      env = {
                        BASE_CACHE = guixCacheDir;
                        BITCOIN_REPO = guixBitcoinRepo;
                        BITCOIN_REPO_URL = bitcoinRepoUrl;
                        CTEST_SITE = ctestSite;
                        GUIX_JOB_DIR = "${guixJob}";
                        SDK_PATH = guixSdkDir;
                        SOURCES_PATH = guixSourcesDir;
                      };
                    };
                    bitcoin-valgrind-fuzz = {
                      command = [
                        "${pkgs.bash}/bin/bash"
                        "${valgrindFuzzJob}/scripts/run-valgrind-fuzz.sh"
                      ];
                      cwd = "${valgrindFuzzJob}";
                      env = {
                        BITCOIN_REPO = valgrindFuzzBitcoinRepo;
                        BITCOIN_REPO_URL = bitcoinRepoUrl;
                        CTEST_SITE = ctestSite;
                        QA_ASSETS_PATH = qaAssetsDir;
                        QA_ASSETS_REPO_URL = qaAssetsRepoUrl;
                        VALGRIND_FUZZ_BUILD_DIR = valgrindFuzzBuildDir;
                        VALGRIND_FUZZ_JOB_DIR = "${valgrindFuzzJob}";
                      };
                    };
                  };
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
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;

              networking.hostName = "beelink";
              networking.networkmanager.enable = true;

              time.timeZone = "Europe/London";
              i18n.defaultLocale = "en_GB.UTF-8";

              services.openssh.enable = true;
              services.guix = {
                enable = true;
                package = pkgs.guix;
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
                "d ${guixSdkDir} 0750 ci-runner ci-runner -"
                "d ${guixSourcesDir} 0750 ci-runner ci-runner -"
                "d ${guixCacheDir} 0750 ci-runner ci-runner -"
                "d ${qaAssetsDir} 0750 ci-runner ci-runner -"
                "d ${valgrindFuzzBuildDir} 0750 ci-runner ci-runner -"
                "d ${workDir} 0750 ci-runner ci-runner -"
                "d ${queueDir} 0750 ci-runner ci-runner -"
                "d ${queueDir}/pending 0750 ci-runner ci-runner -"
                "d ${queueDir}/running 0750 ci-runner ci-runner -"
                "d ${queueDir}/done 0750 ci-runner ci-runner -"
                "d ${queueDir}/failed 0750 ci-runner ci-runner -"
                "d ${queueDir}/watch 0750 ci-runner ci-runner -"
              ];

              systemd.services = {
                ci-runner = {
                  description = "CI queue runner";
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

                ci-nightly-bitcoin-enqueue = {
                  description = "Enqueue Bitcoin Core nightly CI";
                  serviceConfig = {
                    Type = "oneshot";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} enqueue bitcoin-nightly --kind nightly --dedupe-key nightly:bitcoin --replace-pending";
                  };
                };

                ci-watch-bitcoin-guix = {
                  description = "Watch Bitcoin Core Guix CI";
                  wantedBy = [ "multi-user.target" ];
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "simple";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} watch-git-ref bitcoin-guix --remote ${bitcoinRepoUrl}";
                    Restart = "always";
                    RestartSec = "60";
                  };
                };

                ci-watch-bitcoin-valgrind-fuzz = {
                  description = "Watch Bitcoin Core valgrind fuzz CI";
                  wantedBy = [ "multi-user.target" ];
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "simple";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} watch-git-ref bitcoin-valgrind-fuzz --remote ${bitcoinRepoUrl}";
                    Restart = "always";
                    RestartSec = "60";
                  };
                };
              };

              systemd.timers.ci-nightly-bitcoin = {
                description = "Run Bitcoin Core nightly CI";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnCalendar = "*-*-* 00:00:00 UTC";
                  Persistent = true;
                  Unit = "ci-nightly-bitcoin-enqueue.service";
                };
              };

              system.stateVersion = "25.11";
            }
          )
        ];
      };
    };
}
