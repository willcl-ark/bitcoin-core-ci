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
              bitcoinRepo = "${ciHome}/bitcoin";
              bitcoinRepoUrl = "https://github.com/bitcoin/bitcoin";
              ccacheDir = "/var/cache/ci-runner/ccache";
              ccacheMaxSize = "75G";
              workDir = "${ciHome}/work";
              buildLock = "${ciHome}/build.lock";
              ctestSite = "willcl-ark/beelink";
              cdashBuildNamePrefix = "nixpkgs";

              jobs = [
                {
                  name = "gcc";
                  devShell = "gcc";
                  cc = "gcc";
                  preset = "default";
                  next = "ci-nightly-bitcoin-gcc-stdlib-debug.service";
                }
                {
                  name = "gcc-stdlib-debug";
                  devShell = "gcc";
                  cc = "gcc";
                  preset = "gcc-stdlib-debug";
                  buildNameSuffix = "gcc-stdlib-debug";
                  next = "ci-nightly-bitcoin-libcxx-hardened.service";
                }
                {
                  name = "libcxx-hardened";
                  devShell = "libcxx";
                  cc = "clang";
                  preset = "libcxx-hardened";
                  buildNameSuffix = "libcxx-hardened";
                  next = "ci-nightly-bitcoin-gcc-instrumented.service";
                }
                {
                  name = "gcc-instrumented";
                  devShell = "gcc";
                  cc = "gcc";
                  preset = "gcc-instrumented";
                  buildNameSuffix = "instrumented";
                  enableCcache = false;
                  useInstrumentation = true;
                }
              ];

              chainTo = unit: {
                unitConfig = {
                  OnSuccess = unit;
                  OnFailure = unit;
                };
              };

              mkJobService =
                job:
                let
                  unitName = "ci-nightly-bitcoin-${job.name}.service";
                  jobWorkDir = "${workDir}/${job.name}";
                  worktree = "${jobWorkDir}/bitcoin";
                  enableCcache = job.enableCcache or true;
                  script = pkgs.writeShellScript "run-${lib.removeSuffix ".service" unitName}" ''
                    set -euo pipefail

                    cleanup() {
                      set +e
                      if [ -d ${lib.escapeShellArg "${bitcoinRepo}/.git"} ]; then
                        git -C ${lib.escapeShellArg bitcoinRepo} worktree remove --force ${lib.escapeShellArg worktree} 2>/dev/null
                        git -C ${lib.escapeShellArg bitcoinRepo} worktree prune 2>/dev/null
                      fi
                      rm -rf -- ${lib.escapeShellArg jobWorkDir}
                    }
                    trap cleanup EXIT

                    cleanup
                    mkdir -p ${lib.escapeShellArg jobWorkDir}
                    git -C ${lib.escapeShellArg bitcoinRepo} clean -dfx
                    git -C ${lib.escapeShellArg bitcoinRepo} worktree add --detach ${lib.escapeShellArg worktree} HEAD
                    git -C ${lib.escapeShellArg worktree} clean -dfx

                    cd ${lib.escapeShellArg nightlyJob}
                    ${lib.optionalString enableCcache ''
                      export CCACHE_DIR=${lib.escapeShellArg ccacheDir}
                      export CCACHE_MAXSIZE=${lib.escapeShellArg ccacheMaxSize}
                      export CMAKE_C_COMPILER_LAUNCHER=ccache
                      export CMAKE_CXX_COMPILER_LAUNCHER=ccache
                    ''}
                    export CDASH_BUILD_NAME_PREFIX=${lib.escapeShellArg cdashBuildNamePrefix}
                    ${lib.optionalString (
                      job ? buildNameSuffix
                    ) "export CDASH_BUILD_NAME_SUFFIX=${lib.escapeShellArg job.buildNameSuffix}"}
                    ${lib.optionalString (job.useInstrumentation or false) "export CTEST_USE_INSTRUMENTATION=1"}
                    export CTEST_CMAKE_GENERATOR=Ninja
                    export CTEST_CONFIGURE_PRESET=${lib.escapeShellArg job.preset}

                    flock ${lib.escapeShellArg buildLock} \
                      nix develop ${lib.escapeShellArg "${nightlyJob}#${job.devShell}"} \
                      --system x86_64-linux \
                      --no-write-lock-file \
                      --command bash -euo pipefail -c '
                        export CC="$1"
                        ctest --verbose -S scripts/build-unit-test.cmake \
                          -DCTEST_SOURCE_DIRECTORY="$2" \
                          -DCTEST_SITE="$3"
                      ' bash ${lib.escapeShellArg job.cc} ${lib.escapeShellArg worktree} ${lib.escapeShellArg ctestSite}
                  '';
                in
                {
                  name = lib.removeSuffix ".service" unitName;
                  value = lib.recursiveUpdate {
                    description = "Bitcoin Core nightly ${job.name}";
                    path = with pkgs; [
                      bash
                      coreutils
                      util-linux
                      git
                      nix
                    ];
                    serviceConfig = {
                      Type = "oneshot";
                      User = "ci-runner";
                      Group = "ci-runner";
                      WorkingDirectory = nightlyJob;
                      ExecStart = script;
                      TimeoutStartSec = "12h";
                    };
                  } (lib.optionalAttrs (job ? next) (chainTo job.next));
                };
            in
            {
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;

              networking.hostName = "beelink";
              networking.networkmanager.enable = true;

              time.timeZone = "Europe/London";
              i18n.defaultLocale = "en_GB.UTF-8";

              services.openssh.enable = true;

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
                git
                vim
              ];

              systemd.tmpfiles.rules = [
                "d ${ciHome} 0750 ci-runner ci-runner -"
                "d /var/cache/ci-runner 0750 ci-runner ci-runner -"
                "d ${ccacheDir} 0750 ci-runner ci-runner -"
                "d ${workDir} 0750 ci-runner ci-runner -"
              ];

              systemd.services = {
                ci-nightly-bitcoin-clone = lib.recursiveUpdate {
                  description = "Clone Bitcoin Core source for nightly CI";
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [
                    coreutils
                    git
                  ];
                  serviceConfig = {
                    Type = "oneshot";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = pkgs.writeShellScript "clone-ci-nightly-bitcoin" ''
                      set -euo pipefail

                      mkdir -p ${lib.escapeShellArg ciHome}
                      if [ ! -d ${lib.escapeShellArg "${bitcoinRepo}/.git"} ]; then
                        if [ -e ${lib.escapeShellArg bitcoinRepo} ]; then
                          echo "${bitcoinRepo} exists but is not a Git checkout" >&2
                          exit 1
                        fi
                        git clone --depth=1 ${lib.escapeShellArg bitcoinRepoUrl} ${lib.escapeShellArg bitcoinRepo}
                      fi
                    '';
                    TimeoutStartSec = "30min";
                  };
                } (chainTo "ci-nightly-bitcoin-update.service");

                ci-nightly-bitcoin-update = lib.recursiveUpdate {
                  description = "Update Bitcoin Core source for nightly CI";
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  path = with pkgs; [
                    git
                  ];
                  serviceConfig = {
                    Type = "oneshot";
                    User = "ci-runner";
                    Group = "ci-runner";
                    ExecStart = pkgs.writeShellScript "update-ci-nightly-bitcoin" ''
                      set -euo pipefail

                      git -C ${lib.escapeShellArg bitcoinRepo} clean -dfx
                      git -C ${lib.escapeShellArg bitcoinRepo} reset --hard HEAD
                      git -C ${lib.escapeShellArg bitcoinRepo} checkout master
                      git -C ${lib.escapeShellArg bitcoinRepo} pull --ff-only --depth=1 origin master
                      git -C ${lib.escapeShellArg bitcoinRepo} rev-parse HEAD
                    '';
                    TimeoutStartSec = "30min";
                  };
                } (chainTo "ci-nightly-bitcoin-gcc.service");
              }
              // lib.listToAttrs (map mkJobService jobs);

              systemd.timers.ci-nightly-bitcoin = {
                description = "Run Bitcoin Core nightly CI";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnCalendar = "*-*-* 00:00:00 UTC";
                  Persistent = true;
                  Unit = "ci-nightly-bitcoin-clone.service";
                };
              };

              system.stateVersion = "25.11";
            }
          )
        ];
      };
    };
}
