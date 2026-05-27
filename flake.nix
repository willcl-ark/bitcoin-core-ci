{
  description = "Home CI lab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      sops-nix,
      ...
    }:
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

      nixosConfigurations.beelink = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
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
              nightlyJob = ./jobs/bitcoin-core-nightly;
              benchJob = ./jobs/bitcoin-core-bench;
              guixJob = ./jobs/bitcoin-core-guix;
              valgrindFuzzJob = ./jobs/bitcoin-core-valgrind-fuzz;
              bitcoinRepo = "${ciHome}/bitcoin";
              benchBitcoinRepo = "${ciHome}/bitcoin-bench";
              guixBitcoinRepo = "${ciHome}/bitcoin-guix";
              valgrindFuzzBitcoinRepo = "${ciHome}/bitcoin-valgrind-fuzz";
              bitcoinRepoUrl = "https://github.com/bitcoin/bitcoin";
              qaAssetsRepoUrl = "https://github.com/bitcoin-core/qa-assets";
              ccacheDir = "/var/cache/ci-runner/ccache";
              ccacheMaxSize = "75G";
              benchmarkBase = "${ciHome}/benchmarks";
              benchmarkRoot = "${ciHome}/benchmarks/bitcoin-core";
              benchmarkArtifactRoot = "${benchmarkRoot}/artifacts";
              benchmarkDb = "${benchmarkRoot}/benchmarks.sqlite";
              benchmarkRunEnv = "${benchmarkRoot}/run.env";
              benchmarkSiteDir = "${benchmarkRoot}/site";
              benchmarkCpuAffinity = "2,3";
              benchmarkCpusetShield = "2,3,14,15";
              benchmarkCpusetHousekeeping = "0,1,4-13,16-23";
              cloudflaredStateDir = "/var/lib/cloudflared";
              guixSdkDir = "${ciHome}/guix-sdk";
              guixSourcesDir = "${ciHome}/guix-sources";
              guixCacheDir = "/var/cache/ci-runner/guix";
              qaAssetsDir = "${ciHome}/qa-assets";
              valgrindFuzzBuildDir = "${ciHome}/valgrind-fuzz-build";
              workDir = "${ciHome}/work";
              queueDir = "${ciHome}/queue";
              benchmarkQueueRunner = pkgs.writeShellApplication {
                name = "ci-start-bitcoin-bench";
                runtimeInputs = [
                  pkgs.coreutils
                ];
                text = ''
                  set -euo pipefail

                  tmp="${benchmarkRunEnv}.$$"
                  umask 077
                  {
                    printf 'CI_JOB_ID=%q\n' "''${CI_JOB_ID}"
                    printf 'CI_JOB_KIND=%q\n' "''${CI_JOB_KIND:-continuous}"
                    printf 'CI_REVISION=%q\n' "''${CI_REVISION:-}"
                  } > "$tmp"
                  mv "$tmp" "${benchmarkRunEnv}"

                  /run/wrappers/bin/sudo ${pkgs.systemd}/bin/systemctl start ci-bitcoin-bench-run.service
                '';
              };
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
                    bitcoin-bench = {
                      command = [
                        "${benchmarkQueueRunner}/bin/ci-start-bitcoin-bench"
                      ];
                      cwd = "${benchJob}";
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
              initializeBenchmarkState = pkgs.writeShellScript "initialize-benchmark-state" ''
                                set -euo pipefail
                                install -d -m 0750 -o ci-runner -g ci-runner ${benchmarkBase}
                                install -d -m 0750 -o ci-runner -g ci-runner ${benchmarkRoot}
                                install -d -m 0750 -o ci-runner -g ci-runner ${benchmarkArtifactRoot}
                                install -d -m 0755 -o ci-runner -g ci-runner ${benchmarkSiteDir}
                                if [ ! -e ${benchmarkSiteDir}/index.html ]; then
                                  cat > ${benchmarkSiteDir}/index.html <<'EOF'
                <!doctype html>
                <html lang="en">
                <head><meta charset="utf-8"><title>Bitcoin Core Benchmarks</title></head>
                <body><h1>Bitcoin Core Benchmarks</h1><p>Waiting for the first benchmark run.</p></body>
                </html>
                EOF
                                  chown ci-runner:ci-runner ${benchmarkSiteDir}/index.html
                                fi
              '';
              pyperfPython = pkgs.python3.withPackages (pythonPackages: [
                pythonPackages.pyperf
              ]);
              ctestSite = "willcl-ark/beelink";
              cdashBuildNamePrefix = "nixpkgs";
            in
            {
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;
              boot.kernelModules = [ "msr" ];

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
                secrets."cloudflared/tunnel-token" = {
                  owner = "cloudflared";
                  group = "cloudflared";
                  mode = "0400";
                };
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
              users.groups.cloudflared = { };
              users.users.ci-runner = {
                isSystemUser = true;
                group = "ci-runner";
                home = ciHome;
                createHome = true;
              };
              users.users.cloudflared = {
                isSystemUser = true;
                group = "cloudflared";
                home = cloudflaredStateDir;
                createHome = true;
              };

              security.sudo.wheelNeedsPassword = false;
              security.sudo.extraRules = [
                {
                  users = [ "ci-runner" ];
                  commands = [
                    {
                      command = "${pkgs.systemd}/bin/systemctl start ci-bitcoin-bench-run.service";
                      options = [ "NOPASSWD" ];
                    }
                    {
                      command = "${benchJob}/scripts/run-with-cpuset-shield.sh";
                      options = [ "NOPASSWD" ];
                    }
                  ];
                }
              ];

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
                cloudflared
                git
                vim
              ];

              systemd.tmpfiles.rules = [
                "d ${ciHome} 0750 ci-runner ci-runner -"
                "d /var/cache/ci-runner 0750 ci-runner ci-runner -"
                "d ${ccacheDir} 0750 ci-runner ci-runner -"
                "d ${benchmarkBase} 0750 ci-runner ci-runner -"
                "d ${benchmarkRoot} 0750 ci-runner ci-runner -"
                "d ${benchmarkArtifactRoot} 0750 ci-runner ci-runner -"
                "d ${benchmarkSiteDir} 0755 ci-runner ci-runner -"
                "d ${cloudflaredStateDir} 0750 cloudflared cloudflared -"
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

                ci-nightly-bitcoin-enqueue = {
                  description = "Enqueue Bitcoin Core nightly CI";
                  serviceConfig = {
                    Type = "oneshot";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} enqueue bitcoin-nightly --kind nightly --dedupe-key nightly:bitcoin --replace-pending";
                  };
                };

                ci-bitcoin-bench-run = {
                  description = "Run Bitcoin Core continuous benchmark CI with pyperf tuning";
                  path = [
                    pyperfPython
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.git
                    pkgs.nix
                    pkgs.sudo
                    pkgs.systemd
                    pkgs.util-linux
                  ];
                  environment = {
                    BENCHMARK_ARTIFACT_ROOT = benchmarkArtifactRoot;
                    BENCHMARK_CPU_AFFINITY = benchmarkCpuAffinity;
                    BENCHMARK_CPUSET_HOUSEKEEPING = benchmarkCpusetHousekeeping;
                    BENCHMARK_CPUSET_SHIELD = benchmarkCpusetShield;
                    BENCHMARK_DB = benchmarkDb;
                    BENCHMARK_MIN_TIME_MS = "1000";
                    BENCHMARK_SITE_DIR = benchmarkSiteDir;
                    BITCOIN_REPO = benchBitcoinRepo;
                    BITCOIN_REPO_URL = bitcoinRepoUrl;
                    CCACHE_DIR = ccacheDir;
                    CCACHE_MAXSIZE = ccacheMaxSize;
                    CDASH_BUILD_NAME_PREFIX = cdashBuildNamePrefix;
                    CI_JOB_KIND = "continuous";
                    CTEST_SITE = ctestSite;
                    WORK_DIR = workDir;
                  };
                  serviceConfig = {
                    Type = "oneshot";
                    User = "root";
                    Group = "root";
                    EnvironmentFile = "-${benchmarkRunEnv}";
                    WorkingDirectory = benchJob;
                    ExecStartPre = "+${initializeBenchmarkState}";
                    ExecStart = "${pkgs.bash}/bin/bash ${benchJob}/scripts/run-bench-with-pyperf.sh";
                    ExecStopPost = "+${pkgs.coreutils}/bin/rm -f ${benchmarkRunEnv}";
                  };
                };

                ci-bitcoin-bench-dashboard = {
                  description = "Serve Bitcoin Core benchmark dashboard";
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    Type = "simple";
                    ExecStartPre = "+${initializeBenchmarkState}";
                    ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 8080 --directory ${benchmarkSiteDir}";
                    User = "ci-runner";
                    Group = "ci-runner";
                    Restart = "always";
                    RestartSec = "10";
                  };
                };

                ci-bitcoin-bench-cloudflared = {
                  description = "Expose Bitcoin Core benchmark dashboard through Cloudflare Tunnel";
                  wantedBy = [ "multi-user.target" ];
                  wants = [
                    "network-online.target"
                    "ci-bitcoin-bench-dashboard.service"
                  ];
                  after = [
                    "network-online.target"
                    "ci-bitcoin-bench-dashboard.service"
                  ];
                  serviceConfig = {
                    Type = "simple";
                    User = "cloudflared";
                    Group = "cloudflared";
                    WorkingDirectory = cloudflaredStateDir;
                    ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file ${
                      config.sops.secrets."cloudflared/tunnel-token".path
                    }";
                    Restart = "always";
                    RestartSec = "10";
                  };
                };

                ci-watch-bitcoin-bench = {
                  description = "Watch Bitcoin Core benchmark CI";
                  wantedBy = [ "multi-user.target" ];
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [ git ];
                  serviceConfig = {
                    Type = "simple";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${queueDir} watch-git-ref bitcoin-bench --remote ${bitcoinRepoUrl}";
                    Restart = "always";
                    RestartSec = "60";
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
