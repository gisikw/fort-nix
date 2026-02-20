---
id: fort-c8y.29
status: open
deps: []
links: []
created: 2026-01-12T05:37:12.506926653Z
type: task
priority: 3
parent: fort-c8y
---
# Restart fort-consumer-retry timer when needs change on deploy

When new needs are added during a deploy, the fort-consumer-retry timer doesn't immediately trigger. This means new needs wait for the nag interval before first attempting fulfillment.

## Current Behavior

- Timer fires every 5 minutes (OnUnitActiveSec)
- New needs get last_sought = now on first timer run, then wait for nag interval
- If nag = 1h, new needs wait up to 1h before first attempt

## Desired Behavior

- On activation (deploy), if needs.json changed, reset fulfillment state for new needs
- Or: trigger fort-consumer-retry immediately after activation

## Implementation Options

1. Add activation script that compares new vs old needs.json
2. Use systemd Conflicts= to restart timer on fort-consumer.service
3. Clear fulfillment state on activation when needs change


