# mail.gisi.network — aggregated personal mail on q.
#
#   Gmail/Workspace ──IMAP+XOAUTH2── mbsync ──► /var/lib/mail/maildir/<addr>/
#                                    (mailroom)        │
#   /accounts/  ◄── mailroom (Go): OAuth connect,      ▼
#                   sync loop, SMTP relay        Dovecot (127.0.0.1:143)
#                                                  INBOX = every account's INBOX (virtual)
#   mail.gisi.network ── fort identity ── nginx ── Roundcube (php-fpm)
#
# Sending: Roundcube → mailroom SMTP (127.0.0.1:2525) → the From account's
# own Gmail SMTP. Deliverability and Sent copies stay with Google.
#
# Trust: everything listens on loopback only. Roundcube auto-logs-in on the
# identity proxy's X-Forwarded-User, so the firewall restricts who may open
# loopback connections to these ports by uid (mail-lo chain below).
{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  subdomain = "mail";
  origin = "https://${subdomain}.${domain}";

  webPort = 8095; # local Roundcube vhost (fort nginx proxies here)
  apiPort = 8096; # mailroom http
  smtpPort = 2525; # mailroom submission
  imapPort = 143; # dovecot

  mailRoot = "/var/lib/mail";
  secrets = "/var/lib/mail-secrets";
  imapUser = "kevin";

  mailroom = import ../../pkgs/mailroom { inherit pkgs; };
  mbsync = pkgs.isync.override { withCyrusSaslXoauth2 = true; };

  fortlogin = pkgs.runCommand "roundcube-plugin-fortlogin" { } ''
    mkdir -p $out/plugins/fortlogin
    cp ${./fortlogin/fortlogin.php} $out/plugins/fortlogin/fortlogin.php
  '';

  # Unified inbox: every account's INBOX, live (moves/deletes act on the
  # real message, which mbsync then propagates as a Gmail archive).
  virtualInbox = pkgs.writeText "dovecot-virtual" ''
    Accounts/%/INBOX
      all
  '';
in
{
  users.users.mailroom = {
    isSystemUser = true;
    group = "mailroom";
    home = "/var/lib/mailroom";
  };
  users.groups.mailroom = { };

  # The Google OAuth client is shared with vdirsyncer-auth (same Cloud
  # project). Mail needs its own redirect URI + the Gmail scope added there.
  sops.secrets.mail-google-client-id = {
    sopsFile = ../../aspects/dev-sandbox/oauth-client-id.sops;
    format = "binary";
    owner = "mailroom";
    mode = "0400";
  };
  sops.secrets.mail-google-client-secret = {
    sopsFile = ../../aspects/dev-sandbox/oauth-client-secret.sops;
    format = "binary";
    owner = "mailroom";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${mailRoot} 0700 mailroom mailroom"
    "d ${mailRoot}/maildir 0700 mailroom mailroom"
    "d ${mailRoot}/local 0700 mailroom mailroom"
    "d ${mailRoot}/index 0700 mailroom mailroom"
    "d ${mailRoot}/home 0700 mailroom mailroom"
    "d ${mailRoot}/virtual 0700 mailroom mailroom"
    "d ${mailRoot}/virtual/INBOX 0700 mailroom mailroom"
    "C+ ${mailRoot}/virtual/INBOX/dovecot-virtual 0600 mailroom mailroom - ${virtualInbox}"
    "d ${secrets} 0711 root root"
  ];

  # One random password shared by Dovecot (passdb), Roundcube (autologin)
  # and mailroom (SMTP AUTH). Generated once, never in the store.
  systemd.services.mail-secrets = {
    description = "Generate local mail credentials";
    wantedBy = [ "multi-user.target" ];
    before = [ "dovecot.service" "mailroom.service" "phpfpm-roundcube.service" ];
    requiredBy = [ "dovecot.service" "mailroom.service" "phpfpm-roundcube.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -eu
      cd ${secrets}
      if [ ! -s pass ]; then
        head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > pass
      fi
      p=$(cat pass)
      printf '%s' "$p" > roundcube-pass.tmp && chown root:roundcube roundcube-pass.tmp && chmod 0440 roundcube-pass.tmp && mv roundcube-pass.tmp roundcube-pass
      printf '%s' "$p" > mailroom-pass.tmp && chown root:mailroom mailroom-pass.tmp && chmod 0440 mailroom-pass.tmp && mv mailroom-pass.tmp mailroom-pass
      printf '${imapUser}:{PLAIN}%s\n' "$p" > dovecot-passwd.tmp && chown root:dovecot2 dovecot-passwd.tmp && chmod 0440 dovecot-passwd.tmp && mv dovecot-passwd.tmp dovecot-passwd
    '';
  };

  # ---- Dovecot: serve the Maildirs, loopback only ----
  services.dovecot2 = {
    enable = true;
    enableImap = true;
    enablePop3 = false;
    enablePAM = false;
    mailPlugins.globally.enable = [ "virtual" ];
    mailLocation = "maildir:${mailRoot}/local:LAYOUT=fs:INDEX=${mailRoot}/index/local";
    extraConfig = ''
      listen = 127.0.0.1
      service imap-login {
        inet_listener imap {
          address = 127.0.0.1
          port = ${toString imapPort}
        }
        inet_listener imaps {
          port = 0
        }
      }
      mail_home = ${mailRoot}/home

      passdb {
        driver = passwd-file
        args = scheme=PLAIN username_format=%n ${secrets}/dovecot-passwd
      }
      userdb {
        driver = static
        args = uid=mailroom gid=mailroom home=${mailRoot}/home
      }

      # "" is the unified inbox; real folders live under Accounts/ and Local/.
      namespace inbox {
        type = private
        prefix =
        separator = /
        inbox = yes
        location = virtual:${mailRoot}/virtual:INDEX=${mailRoot}/index/virtual
      }
      namespace accounts {
        type = private
        prefix = Accounts/
        separator = /
        location = maildir:${mailRoot}/maildir:LAYOUT=fs:INDEX=${mailRoot}/index/accounts
        list = yes
      }
      namespace local {
        type = private
        prefix = Local/
        separator = /
        location = maildir:${mailRoot}/local:LAYOUT=fs:INDEX=${mailRoot}/index/local
        list = yes
        mailbox Drafts {
          auto = subscribe
          special_use = \Drafts
        }
        mailbox Trash {
          auto = subscribe
          special_use = \Trash
        }
        mailbox Archive {
          auto = subscribe
          special_use = \Archive
        }
      }
    '';
  };
  systemd.services.dovecot.serviceConfig.ReadWritePaths = [ mailRoot ];

  # ---- mailroom: accounts page, sync loop, SMTP relay ----
  systemd.services.mailroom = {
    description = "mailroom (mail account connections, sync, relay)";
    after = [ "network-online.target" "mail-secrets.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils ]; # mbsync PassCmd uses cat
    environment = {
      MAILROOM_STATE = "/var/lib/mailroom";
      MAILROOM_MAILDIR = "${mailRoot}/maildir";
      MAILROOM_ORIGIN = origin;
      MAILROOM_HTTP = "127.0.0.1:${toString apiPort}";
      MAILROOM_SMTP = "127.0.0.1:${toString smtpPort}";
      MAILROOM_SMTP_USER = imapUser;
      MAILROOM_SMTP_PASS_FILE = "${secrets}/mailroom-pass";
      MAILROOM_SYNC_INTERVAL = "5m";
      GOOGLE_CLIENT_ID_FILE = config.sops.secrets.mail-google-client-id.path;
      GOOGLE_CLIENT_SECRET_FILE = config.sops.secrets.mail-google-client-secret.path;
      MBSYNC = "${mbsync}/bin/mbsync";
      HOME = "/var/lib/mailroom";
    };
    serviceConfig = {
      ExecStart = "${mailroom}/bin/mailroom";
      User = "mailroom";
      Group = "mailroom";
      StateDirectory = "mailroom";
      StateDirectoryMode = "0700";
      UMask = "0077";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ mailRoot ];
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      LockPersonality = true;
    };
  };

  # ---- Roundcube (PHP; sandboxed by the firewall rules and php-fpm user) ----
  services.roundcube = {
    enable = true;
    hostName = "roundcube.local";
    package = pkgs.roundcube.withPlugins (_: [ fortlogin ]);
    plugins = [ "fortlogin" "subscriptions_option" "archive" "zipdownload" ];
    maxAttachmentSize = 25;
    extraConfig = ''
      $config['imap_host'] = '127.0.0.1:${toString imapPort}';
      $config['smtp_host'] = '127.0.0.1:${toString smtpPort}';
      $config['smtp_user'] = '%u';
      $config['smtp_pass'] = '%p';
      $config['smtp_auth_type'] = 'PLAIN';
      $config['product_name'] = 'Gisi Mail';
      $config['mail_domain'] = 'kevingisi.com';
      $config['proxy_whitelist'] = ['127.0.0.1'];
      $config['use_https'] = true;
      $config['ip_check'] = false;
      $config['session_lifetime'] = 60 * 24;
      $config['use_subscriptions'] = false;
      $config['create_default_folders'] = false;
      $config['drafts_mbox'] = 'Local/Drafts';
      $config['trash_mbox'] = 'Local/Trash';
      $config['sent_mbox'] = ''';
      $config['junk_mbox'] = ''';
      $config['archive_mbox'] = 'Local/Archive';
      $config['show_real_foldernames'] = true;
      $config['identities_level'] = 0;
      $config['reply_mode'] = 1;
      $config['fortlogin_imap_user'] = '${imapUser}';
      $config['fortlogin_pass_file'] = '${secrets}/roundcube-pass';
      $config['fortlogin_identities_url'] = 'http://127.0.0.1:${toString apiPort}/accounts/identities.json';
      $config['fortlogin_display_name'] = 'Kevin Gisi';
    '';
  };

  # Roundcube's module builds an nginx vhost; keep it on loopback and let
  # fort's mail.${domain} vhost (TLS + identity) proxy to it.
  services.nginx.virtualHosts."roundcube.local" = {
    forceSSL = lib.mkForce false;
    enableACME = lib.mkForce false;
    listen = [{ addr = "127.0.0.1"; port = webPort; }];
    locations."/accounts/" = {
      priority = 1000;
      proxyPass = "http://127.0.0.1:${toString apiPort}";
      extraConfig = ''
        add_header Cache-Control "no-store" always;
      '';
    };
  };

  # Loopback ACL: only the intended processes may connect to these ports.
  # (Header-trusting autologin makes 8095/8096 sensitive to any local user.)
  networking.firewall.extraCommands = ''
    iptables -w -D OUTPUT -o lo -j mail-lo 2>/dev/null || true
    iptables -w -F mail-lo 2>/dev/null || iptables -w -N mail-lo
    iptables -w -A mail-lo -m owner --uid-owner 0 -j RETURN
    iptables -w -A mail-lo -p tcp --dport ${toString webPort} -m owner --uid-owner nginx -j RETURN
    iptables -w -A mail-lo -p tcp --dport ${toString apiPort} -m owner --uid-owner nginx -j RETURN
    iptables -w -A mail-lo -p tcp --dport ${toString apiPort} -m owner --uid-owner roundcube -j RETURN
    iptables -w -A mail-lo -p tcp --dport ${toString smtpPort} -m owner --uid-owner roundcube -j RETURN
    iptables -w -A mail-lo -p tcp --dport ${toString imapPort} -m owner --uid-owner roundcube -j RETURN
    iptables -w -A mail-lo -p tcp -m multiport --dports ${toString webPort},${toString apiPort},${toString smtpPort},${toString imapPort} -j REJECT --reject-with tcp-reset
    iptables -w -A OUTPUT -o lo -j mail-lo
  '';
  networking.firewall.extraStopCommands = ''
    iptables -w -D OUTPUT -o lo -j mail-lo 2>/dev/null || true
  '';

  environment.systemPackages = [ mbsync ];

  fort.cluster.services = [
    {
      name = "mail";
      inherit subdomain;
      port = webPort;
      visibility = "vpn";
      maxBodySize = "40m";
      sso = { mode = "identity"; groups = [ "admin" ]; };
    }
  ];
}
