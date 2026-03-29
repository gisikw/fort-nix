{ config, lib, pkgs, ... }:

let
  domain = config.networking.domain;

  # Enrollment script served to new hardware
  enrollScript = pkgs.writeText "enroll.sh" ''
    #!/bin/sh
    set -eu

    CORE="192.168.1.1"
    ENROLL_PORT="9090"

    echo "==> Fort Nix enrollment (${domain})"
    echo ""

    # Install core's public key for SSH access
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "==> Fetching core public key..."
    curl -sf "http://$CORE:8080/master-key.pub" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "==> Core SSH key installed"

    # Ensure sshd is running
    systemctl start sshd 2>/dev/null || true

    # Collect hardware fingerprint
    IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    MAC=$(ip link show | awk '/state UP/{getline; print $2; exit}')
    DISKS=$(lsblk -dno NAME,SIZE,TYPE | grep disk | tr '\n' '; ')
    RAM=$(awk '/^MemTotal/{print $2}' /proc/meminfo)

    echo "==> Registering with core..."
    echo "    IP:    $IP"
    echo "    MAC:   $MAC"
    echo "    RAM:   ''${RAM}kB"
    echo "    Disks: $DISKS"

    curl -sf -X POST "http://$CORE:$ENROLL_PORT/enroll" \
      -H "Content-Type: application/json" \
      -d "{
        \"ip\": \"$IP\",
        \"mac\": \"$MAC\",
        \"ram_kb\": \"$RAM\",
        \"disks\": \"$DISKS\"
      }"

    echo ""
    echo "==> Enrolled. Waiting for confirmation from core."
    echo "==> This box will reboot into its final config when provisioned."
  '';
in
{
  # Static file server — LAN only, no TLS
  services.nginx = {
    enable = true;
    virtualHosts."core-http" = {
      listen = [{ addr = "0.0.0.0"; port = 8080; }];
      root = "/var/lib/core-http";
      extraConfig = "autoindex on;";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/core-http 0755 root root -"
    # Enrollment script
    "L+ /var/lib/core-http/enroll.sh - - - - ${enrollScript}"
    # Master public key (readable by enrolling hosts)
    "C /var/lib/core-http/master-key.pub 0644 root root - /var/lib/core/master-key.pub"
  ];
}
