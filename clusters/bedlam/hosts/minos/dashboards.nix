let
  devices = import ./devices.nix;
in
{
  security = {
    title = "Security";
    icon = "mdi:shield-home";
    config = {
      title = "Security";
      views = [
        {
          title = "Security";
          path = "security";
          icon = "mdi:shield-home";
          cards = [
            # Alert section (top priority when active)
            {
              type = "conditional";
              conditions = [
                {
                  condition = "state";
                  entity = "timer.security_alert";
                  state_not = "idle";
                }
              ];
              card = {
                type = "vertical-stack";
                cards = [
                  {
                    type = "markdown";
                    content = "## Alert Active\nDoor was opened while armed. Dismiss to silence.";
                  }
                  {
                    type = "tile";
                    entity = "timer.security_alert";
                    name = "Time Until Siren";
                    color = "red";
                  }
                  {
                    type = "button";
                    name = "DISMISS ALERT";
                    icon = "mdi:bell-cancel";
                    tap_action = {
                      action = "call-service";
                      service = "input_button.press";
                      target.entity_id = "input_button.security_dismiss";
                    };
                  }
                ];
              };
            }

            # Current security mode (display only - buttons below for changing)
            {
              type = "tile";
              entity = "input_select.security_mode";
              name = "Security Status";
              icon = "mdi:shield-home";
              vertical = true;
            }

            # Quick arm/disarm buttons
            {
              type = "horizontal-stack";
              cards = [
                {
                  type = "button";
                  name = "Disarm";
                  icon = "mdi:shield-off";
                  tap_action = {
                    action = "call-service";
                    service = "input_select.select_option";
                    target.entity_id = "input_select.security_mode";
                    data.option = "Disarmed";
                  };
                }
                {
                  type = "button";
                  name = "Arm Home";
                  icon = "mdi:shield-home";
                  tap_action = {
                    action = "call-service";
                    service = "input_select.select_option";
                    target.entity_id = "input_select.security_mode";
                    data.option = "Armed (Home)";
                  };
                }
                {
                  type = "button";
                  name = "Arm Away";
                  icon = "mdi:shield-lock";
                  tap_action = {
                    action = "call-service";
                    service = "input_select.select_option";
                    target.entity_id = "input_select.security_mode";
                    data.option = "Armed (Away)";
                  };
                }
              ];
            }

            # Door status
            {
              type = "entities";
              title = "Doors";
              entities = [
                {
                  entity = devices.family_room__door__ext.contact;
                  name = "Family Room";
                  icon = "mdi:door";
                }
                {
                  entity = devices.mudroom__door__ext.contact;
                  name = "Mudroom (Exterior)";
                  icon = "mdi:door";
                }
                {
                  entity = devices.mudroom__door__grg.contact;
                  name = "Mudroom (Garage)";
                  icon = "mdi:door";
                }
              ];
            }

            # Schedule section
            {
              type = "entities";
              title = "Schedule";
              entities = [
                {
                  entity = "input_datetime.security_arm_time";
                  name = "Arm at";
                }
                {
                  entity = "input_boolean.security_arm_schedule_enabled";
                  name = "Arm schedule enabled";
                }
                { type = "divider"; }
                {
                  entity = "input_datetime.security_disarm_time";
                  name = "Disarm at";
                }
                {
                  entity = "input_boolean.security_disarm_schedule_enabled";
                  name = "Disarm schedule enabled";
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
