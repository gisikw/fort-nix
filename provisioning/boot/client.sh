#!/usr/bin/env bash
set -euo pipefail

API="${FORT_PROVISION_URL:-https://provision.gisi.network}"
SECRET_FILE="${FORT_BOOTSTRAP_SECRET_FILE:-/etc/fort-provision/bootstrap-secret}"
WORK=/tmp/fort-provision

say() { printf '\n\033[1;36mFORT // %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFORT // %s\033[0m\n' "$*" >&2; sleep infinity; }

[[ -s "$SECRET_FILE" ]] || die "bootstrap credential missing"
SECRET=$(tr -d '\r\n' < "$SECRET_FILE")
mkdir -p "$WORK"

say "network online; requesting an armed identity"
while true; do
  code=$(curl --silent --show-error --output "$WORK/activation.json" --write-out '%{http_code}' \
    --retry 2 --connect-timeout 10 \
    -X POST -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
    --data "{\"dmi_uuid\":\"$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)\"}" \
    "$API/activate" || true)
  case "$code" in
    200) break ;;
    404|409) printf '.'; sleep 5 ;;
    *) say "activation returned HTTP ${code:-network-error}; retrying"; sleep 10 ;;
  esac
done

HOST=$(jq -er .host "$WORK/activation.json")
PROFILE=$(jq -er .profile "$WORK/activation.json")
TOKEN=$(jq -er .claim_token "$WORK/activation.json")
ARCHIVE_URL=$(jq -er .source_archive_url "$WORK/activation.json")
say "lease claimed: $HOST ($PROFILE)"


UUID=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid)
if [[ "$UUID" == "03000200-0400-0500-0006-000700080009" ]]; then
  IFACE=$(ip route show default | awk 'NR==1 {print $5}')
  MAC=$(cat "/sys/class/net/$IFACE/address")
  UUID=$(python3 - "$MAC" <<'PY'
import sys, uuid
print(uuid.uuid5(uuid.uuid5(uuid.NAMESPACE_DNS, "fort.gisi.network"), sys.argv[1]))
PY
)
fi

mkdir -p /tmp/fort-extra/persist/system/etc/ssh
ssh-keygen -q -t ed25519 -N '' -C "fort-device-$UUID" \
  -f /tmp/fort-extra/persist/system/etc/ssh/ssh_host_ed25519_key
PUBKEY=$(cat /tmp/fort-extra/persist/system/etc/ssh/ssh_host_ed25519_key.pub)
nixos-generate-config --show-hardware-config > "$WORK/hardware-configuration.nix"

say "reporting hardware identity before destructive work"
COMPLETE=$(jq -n --arg uuid "$UUID" --arg pubkey "$PUBKEY" \
  --rawfile hardware "$WORK/hardware-configuration.nix" \
  '{uuid:$uuid,pubkey:$pubkey,hardware_configuration:$hardware}')
curl --fail --show-error -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' --data "$COMPLETE" "$API/complete/$TOKEN"

say "waiting for the controller to prepare host-specific source"
while ! curl --fail --silent --show-error --location -H "Authorization: Bearer $TOKEN" \
  "$API$ARCHIVE_URL" -o "$WORK/source.tar.gz"; do sleep 5; done
mkdir -p "$WORK/source"
tar -xzf "$WORK/source.tar.gz" -C "$WORK/source"
cd "$WORK/source"
HOSTS="clusters/bedlam/hosts"
export CLUSTER=bedlam

say "building $HOST; disks will be repartitioned next"
nix build "$HOSTS/$HOST#nixosConfigurations.$HOST.config.system.build.toplevel" -o "$WORK/system"
nix build "$HOSTS/$HOST#nixosConfigurations.$HOST.config.system.build.diskoScript" -o "$WORK/disko"
"$WORK/disko"
mkdir -p /mnt/persist/system/etc/ssh
cp -a /tmp/fort-extra/persist/system/etc/ssh/. /mnt/persist/system/etc/ssh/
nixos-install --no-root-passwd --system "$WORK/system"

say "installation complete; rebooting into $HOST"
sync
reboot
