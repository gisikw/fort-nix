{ pkgs, webhookURL ? "http://127.0.0.1:8123/api/webhook/fort-notify" }:

pkgs.buildGoModule {
  pname = "notify-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject webhook URL at build time
  ldflags = [
    "-X main.webhookURL=${webhookURL}"
  ];

  meta = with pkgs.lib; {
    description = "Home Assistant notification handler for fort control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
