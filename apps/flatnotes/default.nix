{ subdomain ? "notes", dataDir ? "/var/lib/flatnotes", dataUser ? "root", dataGroup ? "root", rootManifest, ... }:
{ pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
  # Generate a stable secret key from the data directory path
  secretKeyFile = "/var/lib/flatnotes/.secret_key";
in
{
  virtualisation.oci-containers.containers.flatnotes = {
    image = "docker.io/dullage/flatnotes:v5.5.4";
    ports = [ "8089:8080" ];
    environment = {
      FLATNOTES_AUTH_TYPE = "none";  # Using oauth2-proxy gatekeeper for auth
      PUID = "1000";
      PGID = "1000";
    };
    environmentFiles = [ secretKeyFile ];
    volumes = [
      "${dataDir}:/data"
    ];
  };

  # Ensure data directory and secret key exist
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 ${dataUser} ${dataGroup} -"
  ];

  system.activationScripts.flatnotesSecretKey = ''
    if [ ! -f ${secretKeyFile} ]; then
      mkdir -p $(dirname ${secretKeyFile})
      echo "FLATNOTES_SECRET_KEY=$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${secretKeyFile}
      chmod 600 ${secretKeyFile}
    fi
  '';

  fort.cluster.services = [
    {
      name = "flatnotes";
      subdomain = subdomain;
      port = 8089;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
      };
    }
  ];
}
