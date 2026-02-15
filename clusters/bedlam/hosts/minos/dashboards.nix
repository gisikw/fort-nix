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
              icon = "mdi:shield";
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
                  entity = devices.bedroom_3__temp_sensor.temperature;
                  name = "Bedroom 3";
                  icon = "mdi:thermometer";
                }
                {
                  entity = devices.bedroom_3__temp_sensor.humidity;
                  name = "Bedroom 3 Humidity";
                  icon = "mdi:water-percent";
                }
                { type = "divider"; }
                {
                  entity = devices.bedroom_4__temp_sensor.temperature;
                  name = "Bedroom 4";
                  icon = "mdi:thermometer";
                }
                {
                  entity = devices.bedroom_4__temp_sensor.humidity;
                  name = "Bedroom 4 Humidity";
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

            # Garage thermostat
            {
              type = "thermostat";
              entity = devices.garage__thermostat.climate;
              name = "Garage";
            }

            # Boiler room controls
            {
              type = "entities";
              title = "Boiler Room Controls";
              entities = [
                {
                  entity = devices.boiler__dehumidifier.switch;
                  name = "Dehumidifier";
                  icon = "mdi:air-humidifier";
                }
                {
                  entity = devices.boiler__dehumidifier.power;
                  name = "Dehumidifier Power";
                  icon = "mdi:flash";
                }
              ];
            }
          ];
        }
      ];
    };
  };

  cameras = {
    title = "Cameras";
    icon = "mdi:cctv";
    config = {
      title = "Cameras";
      views = [
        {
          title = "Cameras";
          path = "cameras";
          icon = "mdi:cctv";
          cards = [
            {
              type = "picture-entity";
              entity = "camera.upstairs_bedroom_mainstream";
              name = "Upstairs Bedroom";
              camera_image = "camera.upstairs_bedroom_mainstream";
              camera_view = "live";
              tap_action = {
                action = "more-info";
              };
            }
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
          title = "Lights & Switches";
          path = "lights";
          icon = "mdi:lightbulb-group";
          cards = [
            # Bedroom 2 - light card with brightness/color
            {
              type = "light";
              entity = "light.bedroom_2__lights";
              name = "Bedroom 2";
            }

            # Bedroom 3 - light card with brightness/color
            {
              type = "light";
              entity = "light.bedroom_3__lights";
              name = "Bedroom 3";
            }

            # Upstairs Bathroom - light card with brightness/color
            {
              type = "light";
              entity = "light.bath_2__lights";
              name = "Upstairs Bathroom";
            }

            # Exterior lights
            {
              type = "entities";
              title = "Exterior";
              entities = [
                {
                  entity = devices.exterior_light_flood.light;
                  name = "Floodlight";
                  icon = "mdi:outdoor-lamp";
                }
              ];
            }

            # Switches
            {
              type = "entities";
              title = "Switches";
              entities = [
                {
                  entity = devices.kitchen__disposal_switch.switch;
                  name = "Kitchen Disposal";
                  icon = "mdi:water-pump";
                }
                {
                  entity = devices.boiler__dehumidifier.switch;
                  name = "Boiler Dehumidifier";
                  icon = "mdi:air-humidifier";
                }
              ];
            }

            # All lights off
            {
              type = "button";
              name = "All Lights Off";
              icon = "mdi:lightbulb-off";
              tap_action = {
                action = "call-service";
                service = "light.turn_off";
                target.entity_id = [
                  "light.bedroom_2__lights"
                  "light.bedroom_3__lights"
                  "light.bath_2__lights"
                  devices.exterior_light_flood.light
                ];
              };
            }
          ];
        }
      ];
    };
  };
}
