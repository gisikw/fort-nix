// HMAC-SHA256 bearer token validator for nginx njs
// Tokens: base64url(payload).base64url(hmac_sha256(payload, secret))
// Payload: {"sub":"...","exp":...,"jti":"...","label":"..."}

import crypto from 'crypto';
import fs from 'fs';

var secret = '';

function loadSecret() {
  try {
    secret = fs.readFileSync('/var/lib/fort-auth/token-secret').toString().trim();
  } catch (e) {
    // Secret not yet provisioned - all tokens will fail validation
    secret = '';
  }
}

// Load on startup
loadSecret();

function validate(r) {
  // VPN bypass: skip token check for VPN requests when vpnBypass is enabled
  if (r.variables.token_vpn_bypass === '1' && r.variables.is_vpn === '1') {
    return r.return(200);
  }

  var auth = r.headersIn['Authorization'] || '';
  if (!auth.startsWith('Bearer ')) {
    r.return(401, 'missing bearer token');
    return;
  }

  var token = auth.substring(7);
  var parts = token.split('.');
  if (parts.length !== 2) {
    r.return(401, 'malformed token');
    return;
  }

  var payloadB64 = parts[0];
  var signatureB64 = parts[1];

  if (!secret) {
    r.return(500, 'token secret not configured');
    return;
  }

  // Verify HMAC-SHA256 signature
  var expected = crypto.createHmac('sha256', secret)
    .update(payloadB64)
    .digest('base64url');

  if (expected !== signatureB64) {
    r.return(401, 'invalid signature');
    return;
  }

  // Decode payload and check expiry
  try {
    var payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString());
  } catch (e) {
    r.return(401, 'invalid payload');
    return;
  }

  var now = Math.floor(Date.now() / 1000);
  if (payload.exp && payload.exp < now) {
    r.return(401, 'token expired');
    return;
  }

  r.return(200);
}

export default { validate };
