{ }:
let
  rootDir = builtins.toString ../.;

  trim = value:
    let
      match = builtins.match "^[[:space:]]*([^[:space:]]+)[[:space:]]*$" value;
    in
    if match == null then "" else builtins.elemAt match 0;

  envCluster = trim (builtins.getEnv "CLUSTER");

  clusterFilePath = rootDir + "/.cluster";
  fileCluster =
    if builtins.pathExists clusterFilePath then trim (builtins.readFile clusterFilePath) else "";

  clusterName =
    if envCluster != "" then envCluster
    else if fileCluster != "" then fileCluster
    else "bedlam";

  clusterDir = rootDir + "/clusters/" + clusterName;
  clusterManifestPath = clusterDir + "/manifest.nix";

  ensurePath =
    path: description:
    if builtins.pathExists path then path else
      builtins.throw ("Expected " + description + " at " + path + " for cluster '" + clusterName + "'");

  manifest = import (ensurePath clusterManifestPath "cluster manifest");
  hostsDir = ensurePath (clusterDir + "/hosts") "cluster hosts directory";
  devicesDir = ensurePath (clusterDir + "/devices") "cluster devices directory";
in
{
  inherit clusterName clusterDir clusterManifestPath manifest hostsDir devicesDir;
}
