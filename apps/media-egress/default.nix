{ ... }:
{ pkgs, lib, ... }:
let
  # The handoff directory qbittorrent drops finished torrents into.
  # Must match completePath in apps/qbittorrent/default.nix.
  completePath = "/ingest/complete";

  # ursula's SSH *host* key is reused as its client identity. That avoids
  # minting and rotating a separate sops-managed keypair: the host key already
  # identifies the machine, already rotates with reprovisioning, and is already
  # root-only. The forced command below is what makes this safe to accept.
  ursulaHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINKRWMTo3cJn6dXMmXfQTqQgK11hdbYeHpP7dcMzNPTe";

  # sshd runs this INSTEAD of whatever the client asked for; the client's real
  # command arrives in $SSH_ORIGINAL_COMMAND. So this is the whole security
  # boundary: ursula holds a key that can do exactly one thing on q.
  #
  # Critically we require --sender. An rsync server invoked *without* --sender
  # is a receiver, i.e. a write into q. Rejecting that is what keeps this a
  # genuinely one-way pipeline even if ursula is compromised.
  #
  # Every branch here was validated against real rsync-generated command lines
  # and against write/traversal/metacharacter attempts before being committed.
  pullGuard = pkgs.writeShellScript "ingest-pull-guard" ''
    set -f
    ALLOWED_PATH="${completePath}/"
    cmd="''${SSH_ORIGINAL_COMMAND:-}"

    # Reject anything that could chain or substitute another command. set -f
    # above disables globbing so the unquoted word-split below cannot expand.
    case "$cmd" in
      *[\;\&\|\`\$\<\>]*|*"
    "*) echo "rejected: metacharacters" >&2; exit 1 ;;
    esac

    set -- $cmd
    [ "$1" = "rsync" ]    || { echo "rejected: not rsync" >&2; exit 1; }
    [ "$2" = "--server" ] || { echo "rejected: not --server" >&2; exit 1; }
    [ "$3" = "--sender" ] || { echo "rejected: not --sender (write attempt)" >&2; exit 1; }
    shift 3

    last=""
    for a in "$@"; do
      case "$a" in
        -[a-zA-Z.]*|--remove-source-files|--partial-dir=*|--info=*|--log-format=*|--timeout=*|.) ;;
        "$ALLOWED_PATH") ;;
        *) echo "rejected: arg $a" >&2; exit 1 ;;
      esac
      last="$a"
    done

    # Pin the final operand. This is the traversal guard: /ingest/complete/../etc
    # is not string-equal to /ingest/complete/ and so never reaches rsync.
    [ "$last" = "$ALLOWED_PATH" ] || { echo "rejected: bad path $last" >&2; exit 1; }

    exec ${pkgs.rsync}/bin/rsync --server --sender "$@"
  '';
in
{
  # Dedicated identity for the puller rather than logging in as qbittorrent:
  # a system account whose only capability is the forced command above.
  # It needs a real shell because sshd execs forced commands via the login
  # shell -- nologin would break the pull.
  users.users.ingest = {
    isSystemUser = true;
    group = "ingest";
    extraGroups = [ "qbittorrent" ];
    home = "/var/empty";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "command=\"${pullGuard}\",restrict ${ursulaHostKey}"
    ];
  };
  users.groups.ingest = { };

  # --remove-source-files unlinks files, and unlink requires write on the
  # *containing directory*, not the file. A multi-file torrent is a directory
  # created by qbittorrent, so without group-write on those directories the
  # pull would copy successfully and then silently fail to clean up, and every
  # subsequent run would re-transfer the same data forever.
  #
  # UMask=0002 (set on the qbittorrent service) plus the setgid bit on
  # /ingest/complete makes qbittorrent's own subdirectories 2775 and
  # group-owned by qbittorrent, which the ingest user is a member of.
  systemd.services.qbittorrent.serviceConfig.UMask = lib.mkForce "0002";

  # Empty directory skeletons are left behind after --remove-source-files
  # (rsync removes files, never directories). q cleans up after itself rather
  # than widening what ursula is allowed to do over SSH.
  #
  # The -mmin +60 guard keeps this from racing a torrent that qbittorrent has
  # just created but not yet written into.
  systemd.services.ingest-reap = {
    description = "Remove emptied torrent directories from the ingest handoff";
    serviceConfig = {
      Type = "oneshot";
      User = "qbittorrent";
      Group = "qbittorrent";
    };
    unitConfig.ConditionPathIsMountPoint = "/ingest";
    script = ''
      ${pkgs.findutils}/bin/find ${completePath} -mindepth 1 -type d -empty \
        -mmin +60 -delete 2>/dev/null || true
    '';
  };

  systemd.timers.ingest-reap = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
}
