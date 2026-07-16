{
  uuid = "linode-85962061";
  profile = "linode";
  # Updated 2026-07-16: the manifest held a pre-reprovision key; the live host
  # signs control-plane requests with this one (verified via read-file of
  # /etc/ssh/ssh_host_ed25519_key.pub — comment root@fort-linode-8). The stale
  # key made every raishan->consumer callback and GC query fail 401
  # (q-a48dcddb), which left orphaned proxy/dns state unGCable.
  pubkey = ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOU2pDs6mjwYN9JSxMCemyqciLKAH8t+9AjQqKgtAT/p fort-device-linode-85962061'';
  stateVersion = ''25.11'';
}
