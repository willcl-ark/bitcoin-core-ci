{
  ci,
  ciRunner,
  pkgs,
  system,
  ...
}:
let
  guixBitcoinRepo = "${ci.home}/bitcoin-guix";
  guixSdkDir = "${ci.home}/guix-sdk";
  guixSourcesDir = "${ci.home}/guix-sources";
  guixCacheDir = "/var/cache/ci-runner/guix";
in
{
  systemd.tmpfiles.rules = [
    "d ${guixSdkDir} 0750 ci-runner ci-runner -"
    "d ${guixSourcesDir} 0750 ci-runner ci-runner -"
    "d ${guixCacheDir} 0750 ci-runner ci-runner -"
  ];

  ci.runner.jobs.bitcoin-guix = {
    command = [
      "${pkgs.nix}/bin/nix"
      "develop"
      "${ci.flake}#bitcoin-core-guix"
      "--system"
      system
      "--no-write-lock-file"
      "--command"
      "${pkgs.bash}/bin/bash"
      "${ci.jobs.guix}/scripts/run-guix.sh"
    ];
    cwd = "${ci.jobs.guix}";
    env = {
      BASE_CACHE = guixCacheDir;
      BITCOIN_REPO = guixBitcoinRepo;
      BITCOIN_REPO_URL = ci.bitcoinRepoUrl;
      CTEST_SITE = ci.ctestSite;
      GUIX_JOB_DIR = "${ci.jobs.guix}";
      SDK_PATH = guixSdkDir;
      SOURCES_PATH = guixSourcesDir;
    };
  };

  systemd.services.ci-watch-bitcoin-guix = {
    description = "Watch Bitcoin Core Guix CI";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ git ];
    serviceConfig = {
      Type = "simple";
      User = "ci-runner";
      Group = "ci-runner";
      ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${ci.queueDir} watch-git-ref bitcoin-guix --remote ${ci.bitcoinRepoUrl}";
      Restart = "always";
      RestartSec = "60";
    };
  };
}
