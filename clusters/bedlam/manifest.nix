rec {
  name = "bedlam";

  fortConfig = {
    settings = {
      domain = "gisi.network";
      dnsProvider = "porkbun";

      sshKey = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1fUAZLXWXgXfTKxejJHTT8rLpmDoTdJOxDV5m3lUHp fort";
        privateKeyPath = "~/.ssh/fort";
      };

      authorizedDeployKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6yMYrTeaT8CU7pjOVYQ1vP/dJTDan8KmBWSFngWbQ1 fort-deployer"
      ];

      # Age public key for CI to decrypt secrets during release workflow.
      # Private key stored ONLY in Forgejo secrets (CI_AGE_KEY).
      ciAgeKey = "age1r7ezaxn5zvzlkas0fkvuhwduxcj9t2kzdrfe4zjftrlchrngk5ls6tsxke";
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
