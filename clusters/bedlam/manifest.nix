rec {
  name = "bedlam";

  fortConfig = {
    settings = {
      domain = "gisi.network";
      dnsProvider = "porkbun";

      # Principal-based access control
      # Each principal has a publicKey (SSH or age) and roles determining access:
      #   - root: SSH as root to all hosts
      #   - dev-sandbox: SSH as dev user on sandbox hosts
      #   - secrets: Can decrypt secrets on main branch
      principals = {
        admin = {
          description = "Admin user - full access";
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1fUAZLXWXgXfTKxejJHTT8rLpmDoTdJOxDV5m3lUHp fort";
          privateKeyPath = "~/.ssh/fort";
          roles = [ "root" "dev-sandbox" "secrets" ];
        };
        forge = {
          description = "Forge host (drhorrible) - credential distribution";
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6yMYrTeaT8CU7pjOVYQ1vP/dJTDan8KmBWSFngWbQ1 fort-deployer";
          # Private key managed by deployer aspect on drhorrible
          roles = [ "root" ];
        };
        dev-sandbox = {
          description = "Dev sandbox / LLM agents";
          publicKey = "age1c2ydw7l2l5yzsjd77wdf6cd58ya6qseg582femk8yclkndnjqpcq22gl7m";
          agentKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPntyQRxy6bGXLSQY1/jjHwpNhSP5mpHFc4JKUpRVQCR dev-sandbox-agent";
          roles = [ "secrets" ];
        };
        ci = {
          description = "Forgejo CI - secret re-keying only";
          publicKey = "age1r7ezaxn5zvzlkas0fkvuhwduxcj9t2kzdrfe4zjftrlchrngk5ls6tsxke";
          # Private key stored in Forgejo secrets (CI_AGE_KEY)
          roles = [ "secrets" ];
        };
      };
    };

    forge = {
      org = "infra";
      repo = "fort-nix";
      mirrors = {
        github = {
          remote = "github.com/gisikw/fort-nix";
          tokenFile = ./github-mirror-token.age;
        };
      };
    };
  };

  module =
    { config, lib, pkgs, ... }:
    {
      # Fort context options (set by host.nix)
      # Cluster-level options (cluster.settings, cluster.services, cluster.forge) defined in fort.nix
      # Host-level options (host.needs, host.capabilities) defined in fort-agent.nix
      options.fort = {
        host = lib.mkOption {
          type = lib.types.submodule {
            freeformType = lib.types.attrsOf lib.types.anything;
          };
          default = { };
          description = "Host-level metadata (apps, aspects, roles, needs, capabilities)";
        };
        clusterName = lib.mkOption {
          type = lib.types.str;
          description = "Name of the cluster";
        };
        clusterDir = lib.mkOption {
          type = lib.types.str;
          description = "Path to cluster directory";
        };
        clusterHostsDir = lib.mkOption {
          type = lib.types.str;
          description = "Path to cluster hosts directory";
        };
        clusterDevicesDir = lib.mkOption {
          type = lib.types.str;
          description = "Path to cluster devices directory";
        };
      };

      config.fort.cluster.settings = fortConfig.settings;
      config.fort.cluster.forge = fortConfig.forge;

      config.environment.systemPackages = [ pkgs.neovim ];
    };
}
