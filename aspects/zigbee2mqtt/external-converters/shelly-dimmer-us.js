// Shelly Dimmer Gen4 US (S4DM-0A102US)
//
// zigbee2mqtt has no built-in converter for this device: it interviews
// successfully but resolves to `supported: false` with an auto-generated
// definition, which means z2m never publishes a state payload. Without a
// state payload there is no retained `zigbee2mqtt/<ieee>` message, so any
// MQTT consumer (family-hub's light widget) sees the device as unavailable.
//
// Upstream tracking issue: https://github.com/Koenkk/zigbee2mqtt/issues/31731
// (EU sibling: https://github.com/Koenkk/zigbee2mqtt/issues/30176)
//
// Known working:     on/off, brightness, power-on behavior, linkquality,
//                    and power/voltage/current metering (the upstream
//                    reporter said metering was dead; on our unit it works).
// Known NOT working: effects.
//
// Endpoint mapping is REQUIRED, despite the suffixed keys it produces.
//
// A previous revision here dropped m.deviceEndpoints() so that values would
// publish unsuffixed (`state`/`brightness` rather than `state_1`/`brightness_1`),
// which is what family-hub's light widget read. On/off and metering kept
// working, so it looked harmless. It was not: without the endpoint mapping,
// level commands are addressed to no endpoint, and the device silently ignores
// every one of them. Verified live 2026-08-08 -- `brightness`, and
// `brightness_step` all reported success, updated z2m's state, and left the
// bulb at full. Upstream's definition (issue #31731, reporter's own testing)
// includes deviceEndpoints and reports brightness control working.
//
// Consumers must therefore read `state_1`/`brightness_1` and command the
// endpoint topic `zigbee2mqtt/<ieee>/l1/set`. Root-level `state`/`brightness`
// keys may linger in z2m's cache from an earlier interview; they are stale and
// must not be trusted.
//
// Endpoint 239 is Shelly's proprietary WiFi-setup cluster (64513/64514), which
// nothing here consumes; it is mapped only because upstream maps it.
//
// Drop this file in {dataDir}/external_converters/; z2m >= 2.0 auto-loads
// that directory (the old `external_converters` config setting is gone).
// Remove this file once nixpkgs ships a z2m with upstream support.

import * as m from 'zigbee-herdsman-converters/lib/modernExtend';

export default {
    zigbeeModel: ['Dimmer US'],
    model: 'Dimmer US',
    vendor: 'Shelly',
    description: 'Shelly Dimmer Gen4 US (fort-nix external converter)',
    extend: [
        m.deviceEndpoints({ endpoints: { '1': 1, '239': 239 } }),
        m.light(),
        m.electricityMeter(),
    ],
};
