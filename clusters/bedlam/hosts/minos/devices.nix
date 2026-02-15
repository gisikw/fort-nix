let
  mkThirdRealityOutlet = name: {
    ${name} = {
      switch = "switch.${name}";
      power = "sensor.${name}_power";
      energy = "sensor.${name}_energy";
      power_on_behavior = "select.${name}_power_on_behavior";
      update = "update.${name}";
    };
  };

  mkHueLight = name: {
    ${name} = {
      light = "light.${name}";
      update = "update.${name}";
      power_on_behavior = "select.${name}_power_on_behavior";
    };
  };

  mkHueRemote = name: {
    ${name} = {
      action = "sensor.${name}_action";
      update = "update.${name}";
      battery = "sensor.${name}_battery";
    };
  };

  mkAqaraContactSensor = name: {
    ${name} = {
      contact = "binary_sensor.${name}_contact";
      device_temperature = "sensor.${name}_device_temperature";
      battery = "sensor.${name}_battery";
    };
  };

  mkAqaraTemperatureSensor = name: {
    ${name} = {
      temperature = "sensor.${name}_temperature";
      atmospheric_pressure = "sensor.${name}_pressure";
      humidity = "sensor.${name}_humidity";
      battery = "sensor.${name}_battery";
    };
  };

  mkSenckitSiren = name: {
    ${name} = {
      switch = "switch.${name}_alarm";
      melody = "select.${name}_melody";
      volume = "select.${name}_volume";
    };
  };

  mkNotify = name: {
    ${name} = {
      service = "notify.${name}";
    };
  };

  # Z-Wave lights (via zwave-js-ui)
  mkZwaveLight = name: {
    ${name} = {
      light = "light.${name}";
    };
  };

  # Z-Wave dimmer switch (controls a light)
  mkZwaveDimmer = name: {
    ${name} = {
      light = "light.${name}";
    };
  };

  # Aqara switch (simple on/off)
  mkAqaraSwitch = name: {
    ${name} = {
      switch = "switch.${name}";
    };
  };

  # Climate/thermostat
  mkThermostat = name: {
    ${name} = {
      climate = "climate.${name}";
      temperature = "sensor.${name}_temperature";
    };
  };

in
  # bedroom_2
  mkHueLight "bedroom_2__light__ne" //
  mkHueLight "bedroom_2__light__sw" //
  mkAqaraTemperatureSensor "bedroom_2__temp_sensor" //
  mkHueRemote "bedroom_2__remote" //
  mkZwaveDimmer "bedroom_2__switch" //

  # bedroom_3
  mkHueLight "bedroom_3__light__ne" //
  mkHueLight "bedroom_3__light__nw" //
  mkHueLight "bedroom_3__light__se" //
  mkHueLight "bedroom_3__light__sw" //
  mkAqaraTemperatureSensor "bedroom_3__temp_sensor" //
  mkHueRemote "bedroom_3__remote" //
  mkSenckitSiren "bedroom_3__alarm" //

  # Kevin's Room (bedroom_4)
  mkAqaraTemperatureSensor "bedroom_4__temp_sensor" //
  mkSenckitSiren "bedroom_4__alarm" //

  # Upstairs Bathroom (bath_2)
  mkZwaveLight "bath_2__light__vanity_left" //
  mkZwaveLight "bath_2__light__vanity_center" //
  mkZwaveLight "bath_2__light__vanity_right" //
  mkZwaveLight "bath_2__light__toilet" //

  # Family Room
  mkAqaraContactSensor "family_room__door__ext" //

  # Mudroom
  mkAqaraContactSensor "mudroom__door__ext" //
  mkAqaraContactSensor "mudroom__door__grg" //

  # Kitchen
  mkAqaraSwitch "kitchen__disposal_switch" //

  # Boiler Room
  mkAqaraTemperatureSensor "boiler__temp_sensor" //
  mkThirdRealityOutlet "boiler__dehumidifier" //

  # Garage
  mkThermostat "garage__thermostat" //

  # Exterior
  mkZwaveLight "exterior_light_flood" //

  # Notifications
  mkNotify "notify__adult_1"
