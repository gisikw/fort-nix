let
  devices = import ./devices.nix;
in
{
  example_script = {
    alias = "Example Script";
    sequence = [
      {
        service = "light.turn_off";
        target.entity_id = [
          devices.bedroom_3__light__nw.light
        ];
      }
    ];
  };
}
