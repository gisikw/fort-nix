# Note: because HA derives entity_ids from the name field, which may contain
# PII (it's primary use case is for the UI, after all), we don't leverage these
# in automation. They're UI affordances only.
let
  devices = import ./devices.nix;
in
[
  # bedroom_2
  {
    platform = "group";
    name = "!lights__bedroom_2";
    unique_id = "bedroom_2__lights";
    entities = [
      devices.bedroom_2__light__ne.light
      devices.bedroom_2__light__sw.light
    ];
  }

  # bedroom_3
  {
    platform = "group";
    name = "!lights__bedroom_3";
    unique_id = "bedroom_3__lights";
    entities = [
      devices.bedroom_3__light__ne.light
      devices.bedroom_3__light__nw.light
      devices.bedroom_3__light__se.light
      devices.bedroom_3__light__sw.light
    ];
  }

  # Upstairs Bathroom
  {
    platform = "group";
    name = "!lights__bath_2";
    unique_id = "bath_2__lights";
    entities = [
      devices.bath_2__light__vanity_left.light
      devices.bath_2__light__vanity_center.light
      devices.bath_2__light__vanity_right.light
      devices.bath_2__light__toilet.light
    ];
  }
]
