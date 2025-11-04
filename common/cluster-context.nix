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

  hostsDirCandidate = clusterDir + "/hosts";
  devicesDirCandidate = clusterDir + "/devices";
in
{
  inherit
    clusterName
    clusterDir
    clusterManifestPath
    rootDir;

  hasClusterManifest = builtins.pathExists clusterManifestPath;

  hostsDir =
    if builtins.pathExists hostsDirCandidate then hostsDirCandidate else rootDir + "/hosts";

  devicesDir =
    if builtins.pathExists devicesDirCandidate then devicesDirCandidate else rootDir + "/devices";
}
