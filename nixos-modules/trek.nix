{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.trek;
  pkg = cfg.package;
  # Fixed to match the ./data and ./uploads symlinks baked into the trek
  # package itself (see pkgs/trek/default.nix), which mirror the paths
  # upstream's own Docker image bind-mounts host state at.
  stateDir = "/var/lib/trek";
in {
  options.services.trek = {
    enable = lib.mkEnableOption "TREK, a self-hosted collaborative travel planner";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nur.repos.msaxena.trek;
      defaultText = lib.literalExpression "pkgs.nur.repos.msaxena.trek";
      description = "The TREK package to use.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "TCP port TREK listens on.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address TREK binds to. Upstream only expects this to be set outside
        of Docker (where the container itself provides network isolation),
        which applies here.
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      example = "Europe/Berlin";
      description = "Timezone for logs, reminders and scheduled tasks.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum ["info" "debug"];
      default = "info";
      description = ''
        `info` logs concise user actions; `debug` adds verbose admin-level
        details.
      '';
    };

    allowedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["https://trek.example.com"];
      description = ''
        Origins allowed for CORS and used in email links. Required in
        practice once TREK is reachable from anywhere but localhost.
      '';
    };

    appUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://trek.example.com";
      description = ''
        Base URL of this instance. Required when OIDC is enabled, and must
        match the redirect URI registered with the identity provider.
      '';
    };

    forceHttps = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable HTTPS redirect, HSTS, CSP upgrade-insecure-requests and secure
        cookies. Only enable this behind a TLS-terminating reverse proxy.
      '';
    };

    trustProxy = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.ints.unsigned lib.types.bool);
      default = null;
      example = 1;
      description = ''
        Number of trusted reverse-proxy hops, or `true`/`false`. Needed for
        `forceHttps` to work correctly behind a reverse proxy.
      '';
    };

    allowInternalNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow outbound requests to private/RFC1918 addresses, e.g. for a
        LAN-hosted Immich instance. Loopback and link-local addresses are
        always blocked regardless of this setting.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/trek";
      description = ''
        Path to a file containing secret environment variables, loaded by
        systemd before the service starts. Useful for `ENCRYPTION_KEY`,
        `ADMIN_EMAIL`/`ADMIN_PASSWORD` (first boot only), OIDC client
        secrets, SMTP credentials, and similar.

        Use sops-nix or agenix to keep this file out of the Nix store.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open <option>services.trek.port</option> in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.trek = {
      description = "TREK travel planner";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      environment =
        {
          NODE_ENV = "production";
          PORT = toString cfg.port;
          HOST = cfg.listenAddress;
          TZ = cfg.timezone;
          LOG_LEVEL = cfg.logLevel;
          FORCE_HTTPS = lib.boolToString cfg.forceHttps;
          ALLOW_INTERNAL_NETWORK = lib.boolToString cfg.allowInternalNetwork;
        }
        // lib.optionalAttrs (cfg.allowedOrigins != []) {
          ALLOWED_ORIGINS = lib.concatStringsSep "," cfg.allowedOrigins;
        }
        // lib.optionalAttrs (cfg.appUrl != null) {
          APP_URL = cfg.appUrl;
        }
        // lib.optionalAttrs (cfg.trustProxy != null) {
          TRUST_PROXY = if builtins.isBool cfg.trustProxy then lib.boolToString cfg.trustProxy else toString cfg.trustProxy;
        };

      serviceConfig = {
        Type = "simple";

        # DynamicUser means systemd allocates a transient user and owns the
        # StateDirectory. The user name is derived from the service name so
        # it is stable across restarts (but not across rebuilds on
        # impermanent systems).
        DynamicUser = true;

        # Creates /var/lib/trek, chowned to the dynamic user. Subdirectories
        # matching upstream's Docker entrypoint are created below.
        StateDirectory = "trek";
        StateDirectoryMode = "0700";

        ExecStartPre = pkgs.writeShellScript "trek-prestart" ''
          mkdir -p ${stateDir}/data/logs
          mkdir -p ${stateDir}/uploads/files ${stateDir}/uploads/covers ${stateDir}/uploads/avatars ${stateDir}/uploads/photos
        '';

        # The server resolves node_modules, tsconfig.json (for
        # tsconfig-paths) and its "./data" and "./uploads" symlinks (into
        # the state directory) all relative to the working directory, so it
        # must run from within the package's server directory.
        WorkingDirectory = "${pkg}/lib/trek/server";
        ExecStart = "${lib.getExe pkgs.nodejs} --require tsconfig-paths/register ${pkg}/lib/trek/server/dist/index.js";

        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;

        Restart = "on-failure";
        RestartSec = "5s";

        # ── Hardening ──────────────────────────────────────────────────────
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK"];
        RestrictNamespaces = true;
        LockPersonality = true;
        # Node.js JIT requires the ability to map memory as writable+executable.
        MemoryDenyWriteExecute = false;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        ReadWritePaths = [stateDir];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
