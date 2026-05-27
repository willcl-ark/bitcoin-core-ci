{
  ci,
  ciRunner,
  pkgs,
  ...
}:
{
  ci.runner.jobs.bitcoin-nightly = {
    command = [
      "${pkgs.bash}/bin/bash"
      "${ci.jobs.nightly}/scripts/run-nightly.sh"
    ];
    cwd = "${ci.jobs.nightly}";
    env = {
      BITCOIN_REPO = "${ci.home}/bitcoin";
      BITCOIN_REPO_URL = ci.bitcoinRepoUrl;
      CCACHE_DIR = ci.ccache.dir;
      CCACHE_MAXSIZE = ci.ccache.maxSize;
      CDASH_BUILD_NAME_PREFIX = ci.cdashBuildNamePrefix;
      CI_FLAKE = ci.flake;
      CTEST_SITE = ci.ctestSite;
      WORK_DIR = ci.workDir;
    };
  };

  systemd.services.ci-nightly-bitcoin-enqueue = {
    description = "Enqueue Bitcoin Core nightly CI";
    serviceConfig = {
      Type = "oneshot";
      User = "ci-runner";
      Group = "ci-runner";
      ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${ci.queueDir} enqueue bitcoin-nightly --kind nightly --dedupe-key nightly:bitcoin --replace-pending";
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
}
