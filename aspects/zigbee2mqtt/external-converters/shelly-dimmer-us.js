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
// This definition is taken verbatim from the tested one in that issue.
// Known working:     on/off, brightness, power-on behavior, linkquality
// Known NOT working: effects, and all power/energy metering (the
//                    electricityMeter exposes appear but never populate).
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
