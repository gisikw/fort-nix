let
  devices = import ./devices.nix;

  bedroom_2_lights = [
    devices.bedroom_2__light__ne.light
    devices.bedroom_2__light__sw.light
  ];

  egress_doors = [
    devices.family_room__door__ext.contact
    devices.mudroom__door__ext.contact
    devices.mudroom__door__grg.contact
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

  {
    alias = "!automation__egress_door_opened";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = egress_doors; to = "on"; }
    ];
    conditions = [
      {
        condition = "time";
        after = "input_datetime.egress_monitor_start";
        before = "input_datetime.egress_monitor_end";
      }
      {
        condition = "state";
        entity_id = "timer.egress_snooze";
        state = "idle";
      }
    ];
    actions = [
      {
        action = "timer.start";
        target.entity_id = "timer.egress_alert";
        data.duration = "00:00:30";
      }
      {
        action = devices.notify__adult_1.service;
        data = {
          title = "Exterior Door Opened";
          message = "Open app to dismiss if expected";
        };
      }
    ];
  }

  {
    alias = "!automation__egress_escalate";
    mode = "single";
    triggers = [
      {
        platform = "event";
        event_type = "timer.finished";
        event_data.entity_id = "timer.egress_alert";
      }
    ];
    actions = [
      {
        action = "switch.turn_off";
        target.entity_id = devices.bedroom_4__alarm.switch;
      }
      {
        action = "select.select_option";
        target.entity_id = devices.bedroom_4__alarm.melody;
        data.option = "8";
      }
      {
        action = "select.select_option";
        target.entity_id = devices.bedroom_4__alarm.volume;
        data.option = "low";
      }
      {
        action = "switch.turn_on";
        target.entity_id = devices.bedroom_4__alarm.switch;
      }
      {
        action = "timer.start";
        target.entity_id = "timer.egress_alert";
        data.duration = "00:00:30";
      }
    ];
  }

  {
    alias = "!automation__egress_dismiss";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = "input_button.egress_alert_dismiss"; }
    ];
    conditions = [
      {
        condition = "not";
        conditions = [{
          condition = "state";
          entity_id = "input_button.egress_alert_dismiss";
          state = ["unavailable" "unknown"];
        }];
      }
    ];
    actions = [
      {
        action = "timer.cancel";
        target.entity_id = "timer.egress_alert";
      }
      {
        action = "switch.turn_off";
        target.entity_id = devices.bedroom_4__alarm.switch;
      }
      {
        action = devices.notify__adult_1.service;
        data.message = "Door alert cleared";
      }
    ];
  }

  {
    alias = "!automation__egress_snooze";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = "input_select.egress_snooze"; }
    ];
    conditions = [
      {
        condition = "not";
        conditions = [{
          condition = "state";
          entity_id = "input_select.egress_snooze";
          state = ["unavailable" "unknown" "Off"];
        }];
      }
    ];
    actions = [
      {
        choose = [
          {
            conditions = [{ condition = "state"; entity_id = "input_select.egress_snooze"; state = "2 minutes"; }];
            sequence = [{ action = "timer.start"; target.entity_id = "timer.egress_snooze"; data.duration = "00:02:00"; }];
          }
          {
            conditions = [{ condition = "state"; entity_id = "input_select.egress_snooze"; state = "15 minutes"; }];
            sequence = [{ action = "timer.start"; target.entity_id = "timer.egress_snooze"; data.duration = "00:15:00"; }];
          }
          {
            conditions = [{ condition = "state"; entity_id = "input_select.egress_snooze"; state = "1 hour"; }];
            sequence = [{ action = "timer.start"; target.entity_id = "timer.egress_snooze"; data.duration = "01:00:00"; }];
          }
          {
            conditions = [{ condition = "state"; entity_id = "input_select.egress_snooze"; state = "Until morning"; }];
            sequence = [{ action = "timer.start"; target.entity_id = "timer.egress_snooze"; data.duration = "08:00:00"; }];
          }
        ];
      }
      {
        action = "input_select.select_option";
        target.entity_id = "input_select.egress_snooze";
        data.option = "Off";
      }
    ];
  }
]
