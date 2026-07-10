# Fort consumer fulfill loop (q-1f08acd9)
#
# Platform-free: plain jq/coreutils plus the fort CLI, run as a systemd
# oneshot (+ retry timer) on NixOS and a launchd StartInterval daemon on
# darwin. Imported by common/fort/control-plane.nix.
#
# Fulfill script - reads needs.json and calls providers
# New schema: each need has { from, request, handler, nag_seconds }
# Handler is invoked with response body on stdin
{ pkgs, fortCli }:
pkgs.writeShellScript "fort-fulfill" ''
    set -euo pipefail

    NEEDS_FILE="/etc/fort/needs.json"
    FULFILLMENT_STATE_FILE="/var/lib/fort/fulfillment-state.json"

    log() { echo "[fort-fulfill] $*"; }

    # Exit early if no needs file
    if [ ! -f "$NEEDS_FILE" ]; then
      log "No needs.json found, nothing to fulfill"
      exit 0
    fi

    # Load fulfillment state (or init empty)
    if [ -f "$FULFILLMENT_STATE_FILE" ]; then
      fulfillment_state=$(${pkgs.coreutils}/bin/cat "$FULFILLMENT_STATE_FILE")
    else
      fulfillment_state='{}'
    fi

    now=$(${pkgs.coreutils}/bin/date +%s)

    # Read needs.json and process each need
    needs=$(${pkgs.jq}/bin/jq -c '.[]' "$NEEDS_FILE")

    while IFS= read -r need; do
      [ -z "$need" ] && continue

      id=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.id')
      capability=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.capability')
      from=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.from')
      # Inject need ID into request so provider can identify callback target
      request=$(echo "$need" | ${pkgs.jq}/bin/jq -c --arg id "$id" '(.request // {}) + {"_fort_need_id": $id}')
      handler=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.handler')
      nag_seconds=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.nag_seconds // 900')
      never_satisfied=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.never_satisfied // false')
      check=$(echo "$need" | ${pkgs.jq}/bin/jq -r '.check // ""')

      # Get current state for this need
      need_state=$(echo "$fulfillment_state" | ${pkgs.jq}/bin/jq -c --arg id "$id" '.[$id] // {satisfied: false, last_sought: 0, request_hash: ""}')
      satisfied=$(echo "$need_state" | ${pkgs.jq}/bin/jq -r '.satisfied')
      last_sought=$(echo "$need_state" | ${pkgs.jq}/bin/jq -r '.last_sought')
      stored_hash=$(echo "$need_state" | ${pkgs.jq}/bin/jq -r '.request_hash // ""')

      # Freshness probe: a satisfied fulfillment can decay (e.g. the on-disk
      # ssl cert nearing expiry). If the need declares a check script and it
      # fails, mark the need unsatisfied so the normal nag flow re-requests.
      # Nag pacing still applies — a persistently failing check re-requests
      # once per nag interval, not on every 5m fulfill cycle.
      if [ "$satisfied" = "true" ] && [ -n "$check" ]; then
        if ! "$check"; then
          log "[$id] Freshness check failed, marking unsatisfied"
          satisfied="false"
          fulfillment_state=$(echo "$fulfillment_state" | ${pkgs.jq}/bin/jq -c --arg id "$id" \
            '.[$id].satisfied = false')
          # Persist this flag to the state file immediately: the end-of-run
          # merge prefers the file's satisfied=true (protection for callbacks
          # that land mid-run), which would otherwise undo this reset. Only
          # this need's flag is touched so concurrent callback updates for
          # other needs survive.
          if [ -f "$FULFILLMENT_STATE_FILE" ]; then
            file_state=$(${pkgs.coreutils}/bin/cat "$FULFILLMENT_STATE_FILE")
          else
            file_state='{}'
          fi
          echo "$file_state" | ${pkgs.jq}/bin/jq --arg id "$id" \
            '.[$id].satisfied = false' > "$FULFILLMENT_STATE_FILE"
        fi
      fi

      # Compute hash of current request (for change detection)
      current_hash=$(echo "$request" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)

      # Reset satisfaction if request changed (e.g., groups updated)
      # Also reset last_sought to bypass nag interval for parameter changes
      if [ "$stored_hash" != "$current_hash" ] && [ -n "$stored_hash" ]; then
        log "[$id] Request changed (hash mismatch), resetting satisfaction and nag timer"
        satisfied="false"
        last_sought=0
        fulfillment_state=$(echo "$fulfillment_state" | ${pkgs.jq}/bin/jq -c --arg id "$id" \
          '.[$id].satisfied = false | .[$id].last_sought = 0')
      fi

      # Check if already satisfied (skip for never_satisfied needs like runtime packages)
      if [ "$satisfied" = "true" ] && [ "$never_satisfied" != "true" ]; then
        log "[$id] Already satisfied"
        continue
      fi

      # Check nag interval
      elapsed=$((now - last_sought))
      if [ "$elapsed" -lt "$nag_seconds" ]; then
        remaining=$((nag_seconds - elapsed))
        log "[$id] Within nag interval (''${remaining}s remaining)"
        continue
      fi

      # Update last_sought and request_hash before requesting
      fulfillment_state=$(echo "$fulfillment_state" | ${pkgs.jq}/bin/jq -c --arg id "$id" --argjson now "$now" --arg hash "$current_hash" \
        '.[$id] = (.[$id] // {}) | .[$id].last_sought = $now | .[$id].satisfied = false | .[$id].request_hash = $hash')

      log "[$id] Calling $from/$capability..."

      if result=$(${fortCli}/bin/fort "$from" "$capability" "$request" 2>&1); then
        status=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.status')
        body=$(echo "$result" | ${pkgs.jq}/bin/jq -c '.body')

        if [ "$status" = "202" ]; then
          # Async capability - credentials delivered via callback, not sync response
          log "[$id] Async request accepted (HTTP 202), waiting for callback"
        elif [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
          log "[$id] Success from $from (HTTP $status)"

          # Invoke handler with response body on stdin
          if echo "$body" | "$handler"; then
            log "[$id] Handler completed successfully"

            # Mark satisfied in state
            fulfillment_state=$(echo "$fulfillment_state" | ${pkgs.jq}/bin/jq -c --arg id "$id" \
              '.[$id].satisfied = true')
          else
            log "[$id] Handler failed, will retry after nag interval"
          fi
        else
          log "[$id] Provider $from returned HTTP $status"
        fi
      else
        log "[$id] Provider $from failed: $result"
      fi
    done <<< "$needs"

    # Write fulfillment state, merging to preserve callback updates
    # Callbacks update 'satisfied', we update 'last_sought' - merge both
    if [ -f "$FULFILLMENT_STATE_FILE" ]; then
      current_state=$(${pkgs.coreutils}/bin/cat "$FULFILLMENT_STATE_FILE")
    else
      current_state='{}'
    fi

    # Merge: preserve file's 'satisfied' (set by callbacks), use our 'last_sought' and 'request_hash'
    merged_state=$(${pkgs.jq}/bin/jq -n \
      --argjson local "$fulfillment_state" \
      --argjson file "$current_state" \
      '$local | to_entries | map({
        key: .key,
        value: {
          last_sought: .value.last_sought,
          request_hash: .value.request_hash,
          satisfied: ($file[.key].satisfied // .value.satisfied)
        }
      }) | from_entries')

    echo "$merged_state" | ${pkgs.jq}/bin/jq '.' > "$FULFILLMENT_STATE_FILE"
    log "Updated fulfillment state"

    exit 0
  ''
