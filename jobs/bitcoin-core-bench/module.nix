{
  ci,
  ciRunner,
  config,
  pkgs,
  ...
}:
let
  benchmarkBase = "${ci.home}/benchmarks";
  benchmarkRoot = "${benchmarkBase}/bitcoin-core";
  benchmarkArtifactRoot = "${benchmarkRoot}/artifacts";
  benchmarkDb = "${benchmarkRoot}/benchmarks.sqlite";
  benchmarkRunEnv = "${benchmarkRoot}/run.env";
  benchmarkSiteDir = "${benchmarkRoot}/site";
  benchmarkCpuAffinity = "2,3";
  benchmarkCpusetShield = "2,3,14,15";
  benchmarkCpusetHousekeeping = "0,1,4-13,16-23";
  benchBitcoinRepo = "${ci.home}/bitcoin-bench";
  cloudflaredStateDir = "/var/lib/cloudflared";
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
  benchmarkQueueRunner = pkgs.writeShellApplication {
    name = "ci-start-bitcoin-bench";
    runtimeInputs = [
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      tmp="${benchmarkRunEnv}.$$"
      kind="''${CI_JOB_KIND:-continuous}"
      umask 077
      {
        printf 'CI_JOB_ID=%q\n' "''${CI_JOB_ID}"
        printf 'CI_JOB_KIND=%q\n' "$kind"
        printf 'CI_REVISION=%q\n' "''${CI_REVISION:-}"
        if [ "$kind" = backfill-sample ]; then
          printf 'BENCHMARK_RUN_COUNT=1\n'
        fi
      } > "$tmp"
      mv "$tmp" "${benchmarkRunEnv}"

      /run/wrappers/bin/sudo ${pkgs.systemd}/bin/systemctl start ci-bitcoin-bench-run.service
    '';
  };
in
{
  users.groups.cloudflared = { };
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    home = cloudflaredStateDir;
    createHome = true;
  };

  sops.secrets."cloudflared/tunnel-token" = {
    owner = "cloudflared";
    group = "cloudflared";
    mode = "0400";
  };

  security.sudo.extraRules = [
    {
      users = [ "ci-runner" ];
      commands = [
        {
          command = "${pkgs.systemd}/bin/systemctl start ci-bitcoin-bench-run.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${ci.jobs.bench}/scripts/run-with-cpuset-shield.sh";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.tmpfiles.rules = [
    "d ${benchmarkBase} 0750 ci-runner ci-runner -"
    "d ${benchmarkRoot} 0750 ci-runner ci-runner -"
    "d ${benchmarkArtifactRoot} 0750 ci-runner ci-runner -"
    "d ${benchmarkSiteDir} 0755 ci-runner ci-runner -"
    "d ${cloudflaredStateDir} 0750 cloudflared cloudflared -"
  ];

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    virtualHosts.ci-bitcoin-bench-dashboard = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8080;
        }
      ];
      root = benchmarkSiteDir;
      extraConfig = ''
        gzip_static on;
        add_header Cache-Control "public, max-age=60";
      '';
      locations."/".extraConfig = ''
        try_files $uri $uri/ =404;
      '';
    };
  };

  ci.runner.jobs.bitcoin-bench = {
    command = [
      "${benchmarkQueueRunner}/bin/ci-start-bitcoin-bench"
    ];
    cwd = "${ci.jobs.bench}";
  };

  systemd.services = {
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
        BENCHMARK_RUN_COUNT = "5";
        BENCHMARK_SITE_DIR = benchmarkSiteDir;
        BITCOIN_REPO = benchBitcoinRepo;
        BITCOIN_REPO_URL = ci.bitcoinRepoUrl;
        CCACHE_DIR = ci.ccache.dir;
        CCACHE_MAXSIZE = ci.ccache.maxSize;
        CDASH_BUILD_NAME_PREFIX = ci.cdashBuildNamePrefix;
        CI_FLAKE = ci.flake;
        CI_JOB_KIND = "continuous";
        CTEST_SITE = ci.ctestSite;
        WORK_DIR = ci.workDir;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        EnvironmentFile = "-${benchmarkRunEnv}";
        WorkingDirectory = ci.jobs.bench;
        ExecStartPre = "+${initializeBenchmarkState}";
        ExecStart = "${pkgs.bash}/bin/bash ${ci.jobs.bench}/scripts/run-bench-with-pyperf.sh";
        ExecStopPost = "+${pkgs.coreutils}/bin/rm -f ${benchmarkRunEnv}";
      };
    };

    ci-bitcoin-bench-dashboard = {
      description = "Prepare Bitcoin Core benchmark dashboard";
      wantedBy = [ "multi-user.target" ];
      wants = [ "nginx.service" ];
      after = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "+${initializeBenchmarkState}";
      };
    };

    ci-bitcoin-bench-cloudflared = {
      description = "Expose Bitcoin Core benchmark dashboard through Cloudflare Tunnel";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "nginx.service"
        "ci-bitcoin-bench-dashboard.service"
      ];
      after = [
        "network-online.target"
        "nginx.service"
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
        ExecStart = "${ciRunner}/bin/ci-runner --queue-dir ${ci.queueDir} watch-git-ref bitcoin-bench --remote ${ci.bitcoinRepoUrl}";
        Restart = "always";
        RestartSec = "60";
      };
    };
  };
}
