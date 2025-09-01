{ config, lib, pkgs, fort, ... }:

let
  eligibleHosts =
    lib.pipe fort.config.hosts [
      (lib.filterAttrs (_name: cfg:
        !(builtins.elem "fort-citadel" (cfg.roles or []))
      ))
      (lib.attrNames)
      (lib.map (h: "'${h}'"))
      (lib.concatStringsSep " ")
    ];
in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [ just git ];

  services.openssh = {
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
    knownHosts =
      lib.mapAttrs'
        (host: hostCfg:
          let
            device = fort.config.devices.${hostCfg.device};
          in {
            name = "${host}.hosts.${fort.settings.domain}";
            value = {
              publicKey = device.pubkey;
            };
          })
        fort.config.hosts;
  };

  users.groups.fort = {};
  users.extraUsers.fort = {
    isNormalUser = true;
    group = "fort";
    extraGroups = [ "wheel" ];
    home = "/home/fort";
    openssh.authorizedKeys.keys = fort.settings.royal_pubkeys;
  };

  age.secrets.fort-key = {
    file = ../secrets/fort.key.age;
    path = "/home/fort/.ssh/fort";
    mode = "0600";
    owner = "fort";
    group = "fort";
  };

  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  age.secrets.dns-provider-env = {
    file = ../secrets/dns_provider.env.age;
    owner = "root";
    group = "root";
  };

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "admin@${fort.settings.domain}";
      dnsPropagationCheck = false;
    };

    certs.${fort.settings.domain} = {
      domain = fort.settings.domain;
      extraDomainNames = [
        "*.${fort.settings.domain}"
        "*.hosts.${fort.settings.domain}"
        "*.devices.${fort.settings.domain}"
      ];
      dnsProvider = fort.settings.dns_provider;
      environmentFile = config.age.secrets.dns-provider-env.path;
    };
  };

  systemd.services.fort-sync-certs = {
    description = "Sync SSL certs to other hosts";
    after = [ "acme-${fort.settings.domain}.service" ];
    wants = [ "acme-${fort.settings.domain}.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPost = "${pkgs.systemd}/bin/systemctl reload nginx";
    };

    script = ''
      set -euo pipefail

      certdir="/var/lib/acme/${fort.settings.domain}"
      targetdir="/etc/ssl/${fort.settings.domain}"

      ${pkgs.rsync}/bin/rsync -avz --checksum "$certdir/" "$targetdir/"
      chown -R root:nginx /etc/ssl/${fort.settings.domain}
      chmod 640 /etc/ssl/${fort.settings.domain}/*.pem
      chmod 750 /etc/ssl/${fort.settings.domain}

      for host in ${eligibleHosts}; do
        fqdn="$host.hosts.${fort.settings.domain}"
        echo "Syncing cert to $fqdn"

        ${pkgs.rsync}/bin/rsync -avz --checksum \
          -e "${pkgs.openssh}/bin/ssh -i /home/fort/.ssh/fort" \
          "$certdir/" \
          "root@$fqdn:$targetdir/"

        ${pkgs.openssh}/bin/ssh -i /home/fort/.ssh/fort root@$fqdn '
          chown -R root:nginx /etc/ssl/${fort.settings.domain};
          chmod 640 /etc/ssl/${fort.settings.domain}/*.pem;
          chmod 750 /etc/ssl/${fort.settings.domain}
          if systemctl is-active --quiet nginx; then
            systemctl reload nginx
          fi
        '
      done
    '';
  };
}
