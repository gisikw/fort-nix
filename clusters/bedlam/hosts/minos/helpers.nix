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

  input_datetime = {
    security_arm_time = {
      icon = "mdi:shield-lock-outline";
      has_time = true;
      has_date = false;
    };
    security_disarm_time = {
      icon = "mdi:shield-off-outline";
      has_time = true;
      has_date = false;
    };
  };

  input_boolean = {
    security_arm_schedule_enabled = {
      icon = "mdi:calendar-clock";
    };
    security_disarm_schedule_enabled = {
      icon = "mdi:calendar-clock";
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
