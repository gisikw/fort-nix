{ }:
let
  rootDir = ./..;
  envCluster = builtins.getEnv "CLUSTER";

  clusterFilePath = ../.cluster;
  fileCluster =
    if builtins.pathExists clusterFilePath then
      builtins.readFile clusterFilePath
    else
      "";

  clusterName =
    if envCluster != "" then envCluster
    else if fileCluster != "" then fileCluster
    else "bedlam";

  clusterDir = ../clusters/${clusterName};
  clusterManifestPath = clusterDir + "/manifest.nix";
  hasClusterDir = builtins.pathExists clusterDir;
  hasClusterManifest = builtins.pathExists clusterManifestPath;

  hostsDir =
    if hasClusterDir then clusterDir + "/hosts" else "../hosts";
  devicesDir =
    if hasClusterDir then clusterDir + "/devices" else "../devices";
in
{
  inherit
    clusterName
    clusterDir
    clusterManifestPath
    hostsDir
    devicesDir
    hasClusterDir
    hasClusterManifest
    rootDir;
}
