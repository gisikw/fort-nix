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
        ratched = {
          description = "Dev sandbox / LLM agents";
          publicKey = "age1c2ydw7l2l5yzsjd77wdf6cd58ya6qseg582femk8yclkndnjqpcq22gl7m";
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
      options.fort = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };

      config.fort = fortConfig;

      config.environment.systemPackages = [ pkgs.neovim ];
    };
}
