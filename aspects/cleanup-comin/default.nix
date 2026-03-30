{ ... }:
{ pkgs, ... }:
{
  # One-shot cleanup: remove stale /var/lib/comin left from the comin→gitops migration.
  # Remove this aspect once all hosts have been deployed with it.
  systemd.services.cleanup-comin = {
    description = "Remove stale /var/lib/comin directory";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/rm -rf /var/lib/comin
    '';
  };
}
