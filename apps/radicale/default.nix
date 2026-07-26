{ subdomain ? "calendar", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Users who share the `family/` namespace. Each also keeps a private
  # namespace of their own via the [own-*] rules below.
  familyMembers = [ "kevin" "ash" "family" ];

  # Radicale rights, "from_file" backend. Not secret - no sops.
  #
  # Grammar (radicale/rights/from_file.py): INI sections, first match wins.
  # `user` and `collection` are full-match regexes; `{user}` in `collection`
  # interpolates the (regex-escaped) authenticated login.
  #
  # Permission letters (radicale/rights/__init__.py):
  #   R / W  read / write a *regular* collection - e.g. a principal namespace
  #   r / w  read / write an address book or calendar collection - the leaves
  # This mirrors the stock `owner_only` backend (root=R, {user}=RW,
  # {user}/x=rw, anything deeper denied) and adds the shared `family/`
  # namespace on top.
  rightsFile = pkgs.writeText "radicale-rights" ''
    # Every authenticated user may read the root collection, so CalDAV clients
    # can discover their principal. Children are still filtered by the rules
    # below, so this leaks nothing.
    [root]
    user: .+
    collection:
    permissions: R

    # Shared family calendar: kevin, ash and family all get read/write.
    [family-principal]
    user: ${lib.concatStringsSep "|" familyMembers}
    collection: family
    permissions: RW

    [family-calendars]
    user: ${lib.concatStringsSep "|" familyMembers}
    collection: family/[^/]+
    permissions: rw

    # Everyone owns their own principal namespace and the calendars in it.
    [own-principal]
    user: .+
    collection: {user}
    permissions: RW

    [own-calendars]
    user: .+
    collection: {user}/[^/]+
    permissions: rw

    # Deliberately no catch-all: anything unmatched falls through to ""
    # (denied), which is what keeps kevin/ and ash/ private from each other.
  '';
in
{
  sops.secrets.radicale-htpasswd = {
    sopsFile = ./htpasswd.sops;
    format = "binary";
    owner = "radicale";
    group = "radicale";
  };

  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = config.sops.secrets.radicale-htpasswd.path;
        htpasswd_encryption = "bcrypt";
      };
      storage.filesystem_folder = "/var/lib/radicale/collections";
      rights = {
        type = "from_file";
        file = toString rightsFile;
      };
    };
  };

  fort.cluster.services = [
    {
      name = "radicale";
      subdomain = subdomain;
      port = 5232;
      visibility = "public";
      sso.mode = "none"; # Radicale handles auth via htpasswd (CalDAV clients need Basic Auth)
    }
  ];
}
