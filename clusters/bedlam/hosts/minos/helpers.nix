{
  input_datetime = {
    egress_monitor_start = {
      icon = "mdi:clock-start";
      has_time = true;
      has_date = false;
    };
    egress_monitor_end = {
      icon = "mdi:clock-end";
      has_time = true;
      has_date = false;
    };
  };

  input_select = {
    egress_snooze = {
      icon = "mdi:bell-sleep";
      options = [
        "Off"
        "2 minutes"
        "15 minutes"
        "1 hour"
        "Until morning"
      ];
    };
  };

  input_button = {
    egress_alert_dismiss = {
      icon = "mdi:bell-cancel";
    };
  };

  timer = {
    egress_snooze = {
      icon = "mdi:timer-sand";
    };
    egress_alert = {
      icon = "mdi:alarm";
      duration = "00:05:00";
    };
  };
}
