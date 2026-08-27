{ deviceProfileManifest, ... }:
{ config, lib, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'couchdb' is Linux-only (services.couchdb NixOS module); remove it from this darwin host's manifest"
else
  {
    # CouchDB is an internal persistence substrate. Applications reach it over
    # loopback and expose their own bounded/authenticated gateways; CouchDB's
    # credentials and administrative API never leave the host.
    sops.secrets.couchdb-admin = {
      sopsFile = ./admin.ini.sops;
      format = "binary";
      owner = config.services.couchdb.user;
      group = config.services.couchdb.group;
      mode = "0400";
      restartUnits = [ "couchdb.service" ];
    };

    services.couchdb = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 5984;
      extraConfig = {
        couchdb.single_node = true;
        chttpd = {
          require_valid_user = true;
          enable_cors = false;
        };
      };
      # Keep the admin credential out of the Nix store. This file contains only
      # CouchDB's standard [admins] stanza and is decrypted into /run/secrets.
      extraConfigFiles = [ config.sops.secrets.couchdb-admin.path ];
    };

    # Deliberately no firewall opening: this aspect is loopback-only.
  }
