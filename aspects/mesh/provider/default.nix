{ pkgs, ipPath ? "${pkgs.iproute2}/bin/ip" }:

pkgs.buildGoModule {
  pname = "lan-ip-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject ip path at build time
  ldflags = [
    "-X main.ipPath=${ipPath}"
  ];

  meta = with pkgs.lib; {
    description = "LAN IP handler for fort control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
