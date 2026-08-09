{
  subdomain ? null,
  ...
}@args:
{ pkgs, ... }:
let
  # /ingest is the 1TB USB SSD on q (see the host manifest). It is the staging
  # area for acquisition: torrents land here, never on the btrfs system disk.
  ingestRoot = "/ingest";

  # The handoff contract. Anything under completePath is finished and safe for
  # a downstream consumer (ursula) to pull. Nothing else in /ingest is.
  completePath = "${ingestRoot}/complete";
  incompletePath = "${ingestRoot}/incomplete";

  confPath = "/var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf";

  # qBittorrent rewrites its own config on shutdown, so the file cannot be
  # managed declaratively (a symlink into the store would be clobbered, and a
  # read-only file makes qbittorrent log errors and drop *all* settings
  # changes). Instead we patch the three keys we care about on every start and
  # leave the rest of the file alone.
  #
  # Consequence worth knowing: changing the save path in the WebUI will not
  # survive a restart. That is intentional — the path is infrastructure, not a
  # preference. Everything else in the WebUI still persists normally.
  #
  # Key names are the post-4.2 ones (Session\* under [BitTorrent]). The old
  # Downloads\* keys under [Preferences] are silently ignored by modern
  # qbittorrent, which is a quiet way to think you have configured something
  # and have not.
  patchConf = pkgs.writeShellScript "qbittorrent-patch-conf" ''
    set -euo pipefail

    CONF="${confPath}"
    mkdir -p "$(dirname "$CONF")"
    touch "$CONF"

    # A fresh install has no [BitTorrent] section yet.
    grep -q '^\[BitTorrent\]' "$CONF" || printf '[BitTorrent]\n' >> "$CONF"

    # Drop any existing copies, then reinsert. Delete-then-insert (rather than
    # in-place substitution) is what makes this idempotent across restarts and
    # correct when a key is absent.
    sed -i -E '/^Session\\(DefaultSavePath|TempPath|TempPathEnabled)=/d' "$CONF"
    sed -i '/^\[BitTorrent\]/a Session\\DefaultSavePath=${completePath}\nSession\\TempPathEnabled=true\nSession\\TempPath=${incompletePath}' "$CONF"
  '';

  # Runs as root (the '+' prefix below) because /ingest is root-owned and the
  # qbittorrent user cannot mkdir at its top level.
  #
  # These directories are deliberately NOT created via systemd.tmpfiles: tmpfiles
  # runs early in boot and /ingest is mounted 'nofail', so tmpfiles could create
  # complete/ and incomplete/ on the root filesystem underneath the mountpoint,
  # where they would then be shadowed by the real mount. Combined with
  # RequiresMountsFor below, this guarantees we only ever create them on the
  # actual USB SSD.
  ensureDirs = pkgs.writeShellScript "qbittorrent-ensure-dirs" ''
    set -euo pipefail
    install -d -o qbittorrent -g qbittorrent -m 0755 ${completePath} ${incompletePath}
  '';
in
{
  users.groups.qbittorrent = { };
  users.users.qbittorrent = {
    isSystemUser = true;
    home = "/var/lib/qbittorrent";
    createHome = true;
    group = "qbittorrent";
  };

  systemd.services.qbittorrent = {
    after = [ "egress-vpn-namespace.service" ];
    wants = [ "egress-vpn-namespace.service" ];
    wantedBy = [ "multi-user.target" ];

    # /ingest is 'nofail', so the host boots happily without the USB SSD
    # attached. Without this guard qbittorrent would start anyway and download
    # into the bare mountpoint on the btrfs system disk — filling the disk that
    # holds /var/lib for every other service on the box. Refusing to start is
    # the correct failure.
    unitConfig.RequiresMountsFor = ingestRoot;

    serviceConfig = {
      NetworkNamespacePath = "/run/netns/egress-vpn";
      ExecStartPre = [
        "+${ensureDirs}"
        "${patchConf}"
      ];
      ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox";

      Restart = "on-failure";
      RestartSec = 10;
      WorkingDirectory = "/var/lib/qbittorrent";
      User = "qbittorrent";
      Group = "qbittorrent";
    };
  };

  fort.cluster.services = [
    {
      name = "qbittorrent";
      subdomain = subdomain;
      port = 8080;
      inEgressNamespace = true;
      sso = {
        mode = "identity";
        groups = [ "admin" ];
      };
    }
  ];
}
