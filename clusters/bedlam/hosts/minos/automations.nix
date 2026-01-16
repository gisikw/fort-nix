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
    alias = "!automation__security_door_opened";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = egress_doors; to = "on"; }
    ];
    conditions = [
      {
        condition = "not";
        conditions = [{
          condition = "state";
          entity_id = "input_select.security_mode";
          state = "Disarmed";
        }];
      }
      {
        condition = "state";
        entity_id = "timer.security_snooze";
        state = "idle";
      }
    ];
    actions = [
      {
        action = "timer.start";
        target.entity_id = "timer.security_alert";
        data.duration = "00:02:30";
      }
      {
        action = devices.notify__adult_1.service;
        data = {
          title = "🚨 Door Opened While Armed";
          message = "{{ trigger.to_state.attributes.friendly_name }}";
          data.url = "/security-panel/security";
        };
      }
    ];
  }

  {
    alias = "!automation__security_escalate";
    mode = "single";
    triggers = [
      {
        platform = "event";
        event_type = "timer.finished";
        event_data.entity_id = "timer.security_alert";
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
        target.entity_id = "timer.security_alert";
        data.duration = "00:00:30";
      }
    ];
  }

  {
    alias = "!automation__security_dismiss";
    mode = "single";
    triggers = [
      { platform = "state"; entity_id = "input_button.security_dismiss"; }
    ];
    conditions = [
      {
        condition = "not";
        conditions = [{
          condition = "state";
          entity_id = "input_button.security_dismiss";
          state = ["unavailable" "unknown"];
        }];
      }
    ];
    actions = [
      {
        action = "timer.cancel";
        target.entity_id = "timer.security_alert";
      }
      {
        action = "switch.turn_off";
        target.entity_id = devices.bedroom_4__alarm.switch;
      }
      {
        action = devices.notify__adult_1.service;
        data.message = "Alert dismissed (system remains armed)";
      }
    ];
  }

  # Scheduled arm - triggers at configured time if enabled
  {
    alias = "!automation__security_scheduled_arm";
    mode = "single";
    triggers = [
      {
        platform = "time";
        at = "input_datetime.security_arm_time";
      }
    ];
    conditions = [
      {
        condition = "state";
        entity_id = "input_boolean.security_arm_schedule_enabled";
        state = "on";
      }
    ];
    actions = [
      {
        action = "input_select.select_option";
        target.entity_id = "input_select.security_mode";
        data.option = "Armed (Home)";
      }
    ];
  }

  # Scheduled disarm - triggers at configured time if enabled
  {
    alias = "!automation__security_scheduled_disarm";
    mode = "single";
    triggers = [
      {
        platform = "time";
        at = "input_datetime.security_disarm_time";
      }
    ];
    conditions = [
      {
        condition = "state";
        entity_id = "input_boolean.security_disarm_schedule_enabled";
        state = "on";
      }
    ];
    actions = [
      {
        action = "input_select.select_option";
        target.entity_id = "input_select.security_mode";
        data.option = "Disarmed";
      }
    ];
  }

  # Fort notification relay - receives notifications from control plane and forwards to mobile app
  {
    alias = "!automation__fort_notify_relay";
    mode = "queued";
    max = 10;
    triggers = [
      {
        platform = "webhook";
        webhook_id = "fort-notify";
        local_only = true;
        allowed_methods = ["POST"];
      }
    ];
    actions = [
      {
        action = devices.notify__adult_1.service;
        data = {
          title = "{{ trigger.json.title | default('Fort Alert', true) }}";
          message = "{{ trigger.json.message | default('No message provided', true) }}";
          data = {
            url = "{{ trigger.json.url | default(None) }}";
            actions = "{{ trigger.json.actions | default([]) }}";
          };
        };
      }
    ];
  }
]
