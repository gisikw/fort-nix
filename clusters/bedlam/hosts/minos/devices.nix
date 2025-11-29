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
in
  mkHueLight "bedroom_2__light__ne" //
  mkHueLight "bedroom_2__light__sw" //
  mkAqaraTemperatureSensor "bedroom_2__temp_sensor" //
  mkHueRemote "bedroom_2__remote" //

  mkAqaraContactSensor "family_room__door__ext" //

  mkHueLight "bedroom_3__light__ne" //
  mkHueLight "bedroom_3__light__nw" //
  mkHueLight "bedroom_3__light__se" //
  mkHueLight "bedroom_3__light__sw" //

  mkAqaraContactSensor "mudroom__door__ext" //
  mkAqaraContactSensor "mudroom__door__grg" //

  mkAqaraTemperatureSensor "boiler__temp_sensor" //
  mkThirdRealityOutlet "boiler__dehumidifier"
