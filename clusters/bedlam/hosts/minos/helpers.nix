{
  input_select = {
    security_mode = {
      icon = "mdi:shield-home";
      options = [
        "Disarmed"
        "Armed (Home)"
        "Armed (Away)"
      ];
    };
  };

  input_button = {
    security_dismiss = {
      icon = "mdi:bell-cancel";
    };
  };

  timer = {
    security_snooze = {
      icon = "mdi:timer-sand";
    };
    security_alert = {
      icon = "mdi:alarm";
      duration = "00:05:00";
    };
  };
}
