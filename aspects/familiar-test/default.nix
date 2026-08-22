{ ... }:
{ ... }: {
  fort.cluster.services = [{
    name = "familiar-test";
    port = 1692;
    visibility = "public";
    sso = { mode = "identity"; groups = [ "admin" "infra" ]; };
  }];
}
