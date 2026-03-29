{ rootManifest, ... }:
{ ... }:
let
  settings = rootManifest.fortConfig.settings;
  devSandboxKey = settings.principals.dev-sandbox.sshKey or null;
in {
  users.users.root.openssh.authorizedKeys.keys =
    if devSandboxKey != null then [ devSandboxKey ] else [ ];
}
