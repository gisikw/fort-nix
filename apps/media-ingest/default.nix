{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  sourceHost = "q.fort.${domain}";
  sourcePath = "/ingest/complete/";

  # Deliberately NOT a Jellyfin library path. Everything lands here and stays
  # invisible to Jellyfin until Kevin curates it into /media/{movies,shows,...}
  # by hand. That manual promotion step is the point of this directory.
  destPath = "/media/pending";

  # ursula's own SSH host key is the client identity. q's authorized_keys entry
  # for it is pinned to a forced command that can only run an rsync sender on
  # /ingest/complete (see apps/media-egress). Nothing else on q is reachable
  # with this key.
  identity = "/etc/ssh/ssh_host_ed25519_key";

  # q's host key, pinned. Without this the first connection would either fail
  # on an unknown host or, with StrictHostKeyChecking=no, accept whatever
  # answers -- which would defeat the point of pinning an identity at all.
  knownHosts = pkgs.writeText "ingest-known-hosts" ''
    ${sourceHost} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTWsJbTwx8fjcV2l+rH3ww2Anr+vFmWKpnGuKZQjh6O
  '';
in
{
  systemd.services.media-ingest = {
    description = "Pull completed downloads from q into the curation staging area";

    # /media is a ZFS mount. If the pool has not imported, this path exists as
    # an empty directory on the root filesystem -- and pulling into it would
    # write the media library onto the 511G system disk, under a mountpoint
    # that will shadow it on the next successful import. Refuse instead.
    unitConfig.ConditionPathIsMountPoint = "/media";

    serviceConfig = {
      Type = "oneshot";

      # Root because the SSH host key used as our identity is root-only.
      # Compensated by the forced command on q's side: this credential cannot
      # write to q, only read one directory.
      User = "root";
    };

    script = ''
      install -d -o root -g media -m 2775 ${destPath}

      ${pkgs.rsync}/bin/rsync \
        --archive \
        --partial-dir=.rsync-partial \
        --remove-source-files \
        --timeout=300 \
        --chown=root:media \
        --chmod=D2775,F664 \
        -e '${pkgs.openssh}/bin/ssh -i ${identity} -o IdentitiesOnly=yes -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes -o BatchMode=yes' \
        ingest@${sourceHost}:${sourcePath} \
        ${destPath}/
    '';
  };

  systemd.timers.media-ingest = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      # A missed window (host down, pool not imported) runs on next boot rather
      # than waiting for the next quarter hour.
      Persistent = true;
      RandomizedDelaySec = "60";
    };
  };
}
