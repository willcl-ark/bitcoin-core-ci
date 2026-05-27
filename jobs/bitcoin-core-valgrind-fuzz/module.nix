{
  ci,
  ciRunner,
  pkgs,
  ...
}:
let
  qaAssetsDir = "${ci.home}/qa-assets";
  qaAssetsRepoUrl = "https://github.com/bitcoin-core/qa-assets";
  valgrindFuzzBitcoinRepo = "${ci.home}/bitcoin-valgrind-fuzz";
  valgrindFuzzBuildDir = "${ci.home}/valgrind-fuzz-build";
in
{
  systemd.tmpfiles.rules = [
    "d ${qaAssetsDir} 0750 ci-runner ci-runner -"
    "d ${valgrindFuzzBuildDir} 0750 ci-runner ci-runner -"
  ];

  ci.runner.jobs.bitcoin-valgrind-fuzz = {
    command = [
      "${pkgs.bash}/bin/bash"
      "${ci.jobs.valgrindFuzz}/scripts/run-valgrind-fuzz.sh"
    ];
    cwd = "${ci.jobs.valgrindFuzz}";
    env = {
      BITCOIN_REPO = valgrindFuzzBitcoinRepo;
      BITCOIN_REPO_URL = ci.bitcoinRepoUrl;
      CI_FLAKE = ci.flake;
      CTEST_SITE = ci.ctestSite;
      QA_ASSETS_PATH = qaAssetsDir;
      QA_ASSETS_REPO_URL = qaAssetsRepoUrl;
      VALGRIND_FUZZ_BUILD_DIR = valgrindFuzzBuildDir;
      VALGRIND_FUZZ_JOB_DIR = "${ci.jobs.valgrindFuzz}";
    };
  };

  systemd.services.ci-watch-bitcoin-valgrind-fuzz = {
    description = "Watch Bitcoin Core valgrind fuzz CI";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ git ];
    serviceConfig = {
      Type = "simple";
      User = "ci-runner";
      Group = "ci-runner";
      ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${ci.queueDir} watch-git-ref bitcoin-valgrind-fuzz --remote ${ci.bitcoinRepoUrl}";
      Restart = "always";
      RestartSec = "60";
    };
  };
}
