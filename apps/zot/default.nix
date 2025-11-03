{ ... }:
{ pkgs, lib, ... }:
let
  zot = pkgs.stdenv.mkDerivation {
    pname = "zot";
    version = "2.1.10";
    src = pkgs.fetchurl {
      url = "https://github.com/project-zot/zot/releases/download/v2.1.10/zot-linux-amd64";
      sha256 = "sha256-t+7SKehWjZTSt6vMtcxFKJRVG/AbgQjyDf/JuUPQf3A=";
    };
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
    ];
    installPhase = ''
      install -Dm755 $src $out/bin/zot
    '';
  };
in
{
  systemd.services.zot = {
    description = "Zot OCI Registry";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${zot}/bin/zot serve /etc/zot/config.json";
      Restart = "on-failure";
      DynamicUser = true;
      StateDirectory = "zot";
    };
  };

  environment.etc."zot/config.json".text = builtins.toJSON {
    distSpecVersion = "1.1.0";
    storage = {
      rootDirectory = "/var/lib/zot";
      dedupe = true;
    };
    http = {
      address = "127.0.0.1";
      port = 5000;
    };
    extensions = {
      sync = {
        enable = true;
        registries = [
          {
            urls = [ "https://registry-1.docker.io/library" ];
            onDemand = true;
          }
          {
            urls = [ "https://ghcr.io/v2" ];
            content = [
              {
                prefix = "**";
                destination = "/ghcr.io";
              }
            ];
            onDemand = true;
          }
        ];
      };
    };
  };

  fortCluster.exposedServices = [
    {
      name = "containers";
      port = 5000;
    }
  ];
}
