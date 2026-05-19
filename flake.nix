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
                    bitcoin-nightly.unit = "ci-job-bitcoin-nightly.service";
                    bitcoin-guix.unit = "ci-job-bitcoin-guix.service";
                    bitcoin-valgrind-fuzz.unit = "ci-job-bitcoin-valgrind-fuzz.service";
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

              cloneScript =
                name: repo: url: depth:
                pkgs.writeShellScript name ''
                  set -euo pipefail
                  if [ ! -d ${lib.escapeShellArg "${repo}/.git"} ]; then
                    git clone ${
                      lib.optionalString (depth != null) "--depth=${toString depth} "
                    }${lib.escapeShellArg url} ${lib.escapeShellArg repo}
                  fi
                '';
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
                linger = true;
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

              systemd.user.services = {
                ci-runner = {
                  description = "CI queue runner";
                  wantedBy = [ "default.target" ];
                  unitConfig.ConditionUser = "ci-runner";
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} run --config ${runnerConfig}";
                    Restart = "always";
                    RestartSec = "10";
                  };
                };

                ci-nightly-bitcoin-enqueue = {
                  description = "Enqueue Bitcoin Core nightly CI";
                  unitConfig.ConditionUser = "ci-runner";
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} enqueue bitcoin-nightly --kind nightly --dedupe-key nightly:bitcoin --replace-pending";
                  };
                };

                ci-watch-bitcoin-guix = {
                  description = "Watch Bitcoin Core Guix CI";
                  wantedBy = [ "default.target" ];
                  requires = [ "ci-bitcoin-guix-clone.service" ];
                  after = [ "ci-bitcoin-guix-clone.service" ];
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} watch-git-ref bitcoin-guix --repo ${guixBitcoinRepo}";
                    Restart = "always";
                    RestartSec = "60";
                  };
                };

                ci-watch-bitcoin-valgrind-fuzz = {
                  description = "Watch Bitcoin Core valgrind fuzz CI";
                  wantedBy = [ "default.target" ];
                  requires = [ "ci-bitcoin-valgrind-fuzz-clone.service" ];
                  after = [ "ci-bitcoin-valgrind-fuzz-clone.service" ];
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} watch-git-ref bitcoin-valgrind-fuzz --repo ${valgrindFuzzBitcoinRepo}";
                    Restart = "always";
                    RestartSec = "60";
                  };
                };

                ci-bitcoin-nightly-clone = {
                  description = "Clone Bitcoin Core source for nightly CI";
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = cloneScript "clone-ci-bitcoin-nightly" bitcoinRepo bitcoinRepoUrl 1;
                    TimeoutStartSec = "30min";
                  };
                };

                ci-bitcoin-guix-clone = {
                  description = "Clone Bitcoin Core source for Guix CI";
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = cloneScript "clone-ci-bitcoin-guix" guixBitcoinRepo bitcoinRepoUrl null;
                    TimeoutStartSec = "30min";
                  };
                };

                ci-bitcoin-valgrind-fuzz-clone = {
                  description = "Clone Bitcoin Core source for valgrind fuzz CI";
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart =
                      cloneScript "clone-ci-bitcoin-valgrind-fuzz" valgrindFuzzBitcoinRepo bitcoinRepoUrl
                        null;
                    TimeoutStartSec = "30min";
                  };
                };

                ci-bitcoin-qa-assets-clone = {
                  description = "Clone Bitcoin Core qa-assets for valgrind fuzz CI";
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = cloneScript "clone-ci-bitcoin-qa-assets" qaAssetsDir qaAssetsRepoUrl null;
                    TimeoutStartSec = "30min";
                  };
                };

                ci-bitcoin-guix-sdk = {
                  description = "Download Bitcoin Core Guix macOS SDK";
                  unitConfig = {
                    ConditionUser = "ci-runner";
                    ConditionPathExists = "!${guixSdkDir}/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers";
                  };
                  path = with pkgs; [
                    curl
                    gnutar
                  ];
                  serviceConfig = {
                    Type = "oneshot";
                    WorkingDirectory = guixSdkDir;
                    ExecStart = "${pkgs.bash}/bin/bash -c 'curl -fL https://bitcoincore.org/depends-sources/sdks/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers.tar | tar -xf - -C ${guixSdkDir}'";
                    TimeoutStartSec = "30min";
                  };
                };

                ci-job-bitcoin-nightly = {
                  description = "Run Bitcoin Core nightly CI";
                  requires = [ "ci-bitcoin-nightly-clone.service" ];
                  after = [ "ci-bitcoin-nightly-clone.service" ];
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [
                    bash
                    coreutils
                    git
                    nix
                  ];
                  environment = {
                    BITCOIN_REPO = bitcoinRepo;
                    CCACHE_DIR = ccacheDir;
                    CCACHE_MAXSIZE = ccacheMaxSize;
                    CDASH_BUILD_NAME_PREFIX = cdashBuildNamePrefix;
                    CTEST_SITE = ctestSite;
                    WORK_DIR = workDir;
                  };
                  serviceConfig = {
                    Type = "oneshot";
                    WorkingDirectory = nightlyJob;
                    ExecStart = "${pkgs.bash}/bin/bash ${nightlyJob}/scripts/run-nightly.sh";
                    TimeoutStartSec = "12h";
                  };
                };

                ci-job-bitcoin-guix = {
                  description = "Run Bitcoin Core Guix CI";
                  requires = [
                    "ci-bitcoin-guix-clone.service"
                    "ci-bitcoin-guix-sdk.service"
                  ];
                  after = [
                    "ci-bitcoin-guix-clone.service"
                    "ci-bitcoin-guix-sdk.service"
                  ];
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [
                    bash
                    cmake
                    coreutils
                    findutils
                    git
                    guix
                  ];
                  environment = {
                    BASE_CACHE = guixCacheDir;
                    BITCOIN_REPO = guixBitcoinRepo;
                    CTEST_SITE = ctestSite;
                    GUIX_JOB_DIR = guixJob;
                    SDK_PATH = guixSdkDir;
                    SOURCES_PATH = guixSourcesDir;
                  };
                  serviceConfig = {
                    Type = "oneshot";
                    WorkingDirectory = guixBitcoinRepo;
                    ExecStart = "${pkgs.bash}/bin/bash ${guixJob}/scripts/run-guix.sh";
                    TimeoutStartSec = "12h";
                  };
                };

                ci-job-bitcoin-valgrind-fuzz = {
                  description = "Run Bitcoin Core valgrind fuzz CI";
                  requires = [
                    "ci-bitcoin-valgrind-fuzz-clone.service"
                    "ci-bitcoin-qa-assets-clone.service"
                  ];
                  after = [
                    "ci-bitcoin-valgrind-fuzz-clone.service"
                    "ci-bitcoin-qa-assets-clone.service"
                  ];
                  unitConfig.ConditionUser = "ci-runner";
                  path = with pkgs; [
                    bash
                    coreutils
                    git
                    nix
                  ];
                  environment = {
                    BITCOIN_REPO = valgrindFuzzBitcoinRepo;
                    CTEST_SITE = ctestSite;
                    QA_ASSETS_PATH = qaAssetsDir;
                    VALGRIND_FUZZ_BUILD_DIR = valgrindFuzzBuildDir;
                    VALGRIND_FUZZ_JOB_DIR = valgrindFuzzJob;
                  };
                  serviceConfig = {
                    Type = "oneshot";
                    WorkingDirectory = valgrindFuzzJob;
                    ExecStart = "${pkgs.bash}/bin/bash ${valgrindFuzzJob}/scripts/run-valgrind-fuzz.sh";
                    TimeoutStartSec = "12h";
                  };
                };
              };

              systemd.user.timers.ci-nightly-bitcoin = {
                description = "Run Bitcoin Core nightly CI";
                wantedBy = [ "timers.target" ];
                unitConfig.ConditionUser = "ci-runner";
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
