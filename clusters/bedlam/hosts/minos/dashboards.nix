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

  climate = {
    title = "Climate";
    icon = "mdi:thermometer";
    config = {
      title = "Climate";
      views = [
        {
          title = "Climate";
          path = "climate";
          icon = "mdi:thermometer";
          cards = [
            # Weather forecast
            {
              type = "weather-forecast";
              entity = "weather.forecast_home";
              show_forecast = true;
              forecast_type = "daily";
            }

            # Indoor temperatures
            {
              type = "entities";
              title = "Indoor Temperatures";
              entities = [
                {
                  entity = devices.bedroom_2__temp_sensor.temperature;
                  name = "Bedroom 2";
                  icon = "mdi:thermometer";
                }
                {
                  entity = devices.bedroom_2__temp_sensor.humidity;
                  name = "Bedroom 2 Humidity";
                  icon = "mdi:water-percent";
                }
                { type = "divider"; }
                {
                  entity = devices.boiler__temp_sensor.temperature;
                  name = "Boiler Room";
                  icon = "mdi:thermometer";
                }
                {
                  entity = devices.boiler__temp_sensor.humidity;
                  name = "Boiler Room Humidity";
                  icon = "mdi:water-percent";
                }
              ];
            }

            # Boiler room controls
            {
              type = "entities";
              title = "Boiler Room";
              entities = [
                {
                  entity = devices.boiler__dehumidifier.switch;
                  name = "Dehumidifier";
                  icon = "mdi:air-humidifier";
                }
                {
                  entity = devices.boiler__dehumidifier.power;
                  name = "Power Usage";
                  icon = "mdi:flash";
                }
              ];
            }

            # Garage thermostat (placeholder - entity TBD)
            # TODO: Add garage thermostat once entity is identified
          ];
        }
      ];
    };
  };

  lights = {
    title = "Lights";
    icon = "mdi:lightbulb-group";
    config = {
      title = "Lights & Switches";
      views = [
        {
          title = "Lights";
          path = "lights";
          icon = "mdi:lightbulb-group";
          cards = [
            # Bedroom 2
            {
              type = "vertical-stack";
              cards = [
                {
                  type = "markdown";
                  content = "## Bedroom 2";
                }
                {
                  type = "horizontal-stack";
                  cards = [
                    {
                      type = "light";
                      entity = devices.bedroom_2__light__ne.light;
                      name = "NE";
                    }
                    {
                      type = "light";
                      entity = devices.bedroom_2__light__sw.light;
                      name = "SW";
                    }
                  ];
                }
              ];
            }

            # Bedroom 3
            {
              type = "vertical-stack";
              cards = [
                {
                  type = "markdown";
                  content = "## Bedroom 3";
                }
                {
                  type = "horizontal-stack";
                  cards = [
                    {
                      type = "light";
                      entity = devices.bedroom_3__light__nw.light;
                      name = "NW";
                    }
                    {
                      type = "light";
                      entity = devices.bedroom_3__light__ne.light;
                      name = "NE";
                    }
                  ];
                }
                {
                  type = "horizontal-stack";
                  cards = [
                    {
                      type = "light";
                      entity = devices.bedroom_3__light__sw.light;
                      name = "SW";
                    }
                    {
                      type = "light";
                      entity = devices.bedroom_3__light__se.light;
                      name = "SE";
                    }
                  ];
                }
              ];
            }

            # All lights quick controls
            {
              type = "horizontal-stack";
              cards = [
                {
                  type = "button";
                  name = "All Off";
                  icon = "mdi:lightbulb-off";
                  tap_action = {
                    action = "call-service";
                    service = "light.turn_off";
                    target.entity_id = [
                      devices.bedroom_2__light__ne.light
                      devices.bedroom_2__light__sw.light
                      devices.bedroom_3__light__nw.light
                      devices.bedroom_3__light__ne.light
                      devices.bedroom_3__light__sw.light
                      devices.bedroom_3__light__se.light
                    ];
                  };
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
