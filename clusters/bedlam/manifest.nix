rec {
  name = "bedlam";

  fortConfig = {
    settings = {
      domain = "gisi.network";
      dnsProvider = "porkbun";
      vpn = {
        ipv4Prefix = "100.101.0.0/16";
        ipv6Prefix = "fd7a:115c:a1e0:8249::/64";
      };

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
          description = "Forgejo CI - secret re-keying and control plane access";
          publicKey = "age13c897rs6c296uj8nuj84xcgmhwghmcc6ufzps02z64zq8vgtld0qdh3e4d";
          # Age key stored in Forgejo secrets (CI_AGE_KEY) for secret re-keying
          # SSH key for control plane auth (refresh capability)
          agentKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICBy4EkPwAF50uYBRNWj3pRUH9/gyWuOmVquZyqz6SD/ ci-agent";
          roles = [ "secrets" ];
        };
      };
    };

    forge = {
      org = "infra";
      repo = "fort-nix";  # Primary repo (used by gitops)
      repos = {
        "fort-nix" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/fort-nix";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];  # Explicitly exclude release - CI scans before push
            };
          };
        };
        "wicket" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/wicket";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" "release" ];
            };
          };
        };
        "bz" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/bz";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" "release" ];
            };
          };
        };
        "dwim" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/dwim";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" "release" ];
            };
          };
        };
        "unum" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/unum";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "tk-build" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/tk-build";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "knockout" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/knockout";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "gee" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/gee";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "nerve" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/nerve";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "punchlist" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/punchlist";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "punchlist-server" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/punchlist-server";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "crane" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/crane";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "litmus" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/litmus";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
        };
        "barely-game-console" = {
          mirrors = {
            github = {
              remote = "github.com/gisikw/barely-game-console";
              tokenFile = ./github-mirror-token.age;
              branches = [ "main" ];
            };
          };
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
