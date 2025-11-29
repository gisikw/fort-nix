# Note: because HA derives entity_ids from the name field, which may contain
# PII (it's primary use case is for the UI, after all), we don't leverage these
# in automation. They're UI affordances only.
let
  devices = import ./devices.nix;
in
[
  {
    platform = "group";
    name = "!lights__bedroom_2";
    unique_id = "bedroom_2__lights";
    entities = [
      devices.bedroom_2__light__ne.light
      devices.bedroom_2__light__sw.light
    ];
  }
]
