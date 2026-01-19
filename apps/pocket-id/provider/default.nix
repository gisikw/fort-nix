{ pkgs, domain }:

pkgs.buildGoModule {
  pname = "oidc-register-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject domain at build time via ldflags
  ldflags = [
    "-X main.defaultPocketIDURL=https://id.${domain}"
  ];

  meta = with pkgs.lib; {
    description = "OIDC client registration handler for pocket-id";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
