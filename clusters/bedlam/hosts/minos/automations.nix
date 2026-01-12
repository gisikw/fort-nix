let
  devices = import ./devices.nix;
  bedroom_2_lights = [
    devices.bedroom_2__light__ne.light
    devices.bedroom_2__light__sw.light
  ];
in
[
  {
    alias = "!automation__bedroom_2_remote";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = devices.bedroom_2__remote.action; to = "on_press"; id = "on"; }
      { platform = "state"; entity_id = devices.bedroom_2__remote.action; to = "off_press"; id = "off"; }
      { platform = "state"; entity_id = devices.bedroom_2__remote.action; to = "up_press"; id = "up"; }
      { platform = "state"; entity_id = devices.bedroom_2__remote.action; to = "down_press"; id = "down"; }
    ];
    actions = [{
      choose = [
        {
          conditions = [{ condition = "trigger"; id = "on"; }];
          sequence = [{
            action = "light.toggle";
            target.entity_id = bedroom_2_lights;
          }];
        }
        {
          conditions = [{ condition = "trigger"; id = "off"; }];
          sequence = [{
            action = "light.turn_on";
            target.entity_id = bedroom_2_lights;
            data = {
              hs_color = "{{ [(state_attr(target.entity_id[0], 'hs_color')[0] + 30) % 360, state_attr(target.entity_id[0], 'hs_color')[1]] }}";
            };
          }];
        }
        {
          conditions = [{ condition = "trigger"; id = "up"; }];
          sequence = [{
            action = "light.turn_on";
            target.entity_id = bedroom_2_lights;
            data = {
              brightness_step_pct = 10;
            };
          }];
        }
        {
          conditions = [{ condition = "trigger"; id = "down"; }];
          sequence = [{
            action = "light.turn_on";
            target.entity_id = bedroom_2_lights;
            data = {
              brightness_step_pct = -10;
            };
          }];
        }
      ];
    }];
  }
]
