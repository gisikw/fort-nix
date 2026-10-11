# cal-write: Kes's narrow write path to Kev's ASG Google calendar.
#
# vdirsyncer's Google pairs stay read_only; this is the only writer. It uses
# the stored refresh token (full calendar scope, which CalDAV needs anyway),
# mints a short-lived access token in memory (never rewrites the token file,
# so it can't race vdirsyncer), and only ever creates events, or deletes
# events it created itself (tagged extendedProperties.private.createdBy=kes).
#
#   cal-write ooo  START END TITLE     # out-of-office block (auto-declines nothing)
#   cal-write busy START END TITLE     # plain busy block
#   cal-write list [DAYS]              # events this tool created, next DAYS (default 120)
#   cal-write delete EVENT_ID          # only if createdBy=kes
#
# START/END: "YYYY-MM-DD HH:MM" in America/Chicago.
# Env: CAL_ACCOUNT (default kgisi@alpinesg.com, the only account allowed),
#      VD_DATA (default /var/lib/vdirsyncer), VD_HOME (default /home/dev).
set -euo pipefail
# shellcheck disable=SC2154  # CLIENT_ID/CLIENT_SECRET come from google-client.env

account="${CAL_ACCOUNT:-kgisi@alpinesg.com}"
allowed="kgisi@alpinesg.com"
data="${VD_DATA:-/var/lib/vdirsyncer}"
home="${VD_HOME:-/home/dev}"
tz="America/Chicago"
api="https://www.googleapis.com/calendar/v3/calendars/primary/events"

die() { echo "cal-write: $*" >&2; exit 1; }
[ "$account" = "$allowed" ] || die "writes are only allowed to $allowed"

tokfile="$data/tokens/$account.json"
[ -f "$tokfile" ] || tokfile="$data/token"   # the original ASG token
[ -r "$tokfile" ] || die "no token for $account"

# shellcheck disable=SC1091
. "$home/.config/vdirsyncer/google-client.env"
rt="$(jq -er .refresh_token "$tokfile")" || die "token has no refresh_token"
at="$(curl -fsS https://oauth2.googleapis.com/token \
  --data-urlencode grant_type=refresh_token \
  --data-urlencode "refresh_token=$rt" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" | jq -er .access_token)" \
  || die "token refresh failed (Reconnect on https://vdirsyncer-auth.gisi.network/)"

# Guard against the legacy token belonging to someone else.
who="$(curl -fsS -H "Authorization: Bearer $at" \
  "https://www.googleapis.com/calendar/v3/calendars/primary" | jq -r .id)"
[ "$who" = "$account" ] || die "token is for $who, not $account"

# Wall-clock time in $tz; Google applies the zone given in timeZone.
iso() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] \
    || die "bad time '$1' (want YYYY-MM-DD HH:MM)"
  echo "${1/ /T}:00"
}

create() {
  local kind="$1" start end title body
  start="$(iso "$2")"; end="$(iso "$3")"; title="$4"
  body="$(jq -n --arg s "$start" --arg e "$end" --arg t "$title" --arg tz "$tz" --arg k "$kind" '
    {summary: $t,
     start: {dateTime: $s, timeZone: $tz},
     end:   {dateTime: $e, timeZone: $tz},
     transparency: "opaque",
     extendedProperties: {private: {createdBy: "kes"}}}
    + (if $k == "ooo" then
         {eventType: "outOfOffice",
          outOfOfficeProperties: {autoDeclineMode: "declineNone"}}
       else {} end)')"
  curl -fsS -X POST -H "Authorization: Bearer $at" -H 'Content-Type: application/json' \
    --data "$body" "$api" | jq -c '{id, summary, eventType, start: .start.dateTime, end: .end.dateTime, htmlLink}'
}

case "${1:-}" in
  ooo|busy)
    [ $# -eq 4 ] || die "usage: cal-write $1 'YYYY-MM-DD HH:MM' 'YYYY-MM-DD HH:MM' TITLE"
    create "$1" "$2" "$3" "$4" ;;
  list)
    days="${2:-120}"
    curl -fsS -G -H "Authorization: Bearer $at" "$api" \
      --data-urlencode "privateExtendedProperty=createdBy=kes" \
      --data-urlencode "timeMin=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "timeMax=$(date -u -d "+$days days" +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode singleEvents=true --data-urlencode orderBy=startTime \
      | jq -c '.items[] | {id, summary, eventType, start: .start.dateTime, end: .end.dateTime}' ;;
  delete)
    [ $# -eq 2 ] || die "usage: cal-write delete EVENT_ID"
    owner="$(curl -fsS -H "Authorization: Bearer $at" "$api/$2" \
      | jq -r '.extendedProperties.private.createdBy // ""')"
    [ "$owner" = "kes" ] || die "refusing: event $2 wasn't created by cal-write"
    curl -fsS -X DELETE -H "Authorization: Bearer $at" "$api/$2" && echo "deleted $2" ;;
  *) echo "usage: cal-write ooo|busy START END TITLE | list [DAYS] | delete EVENT_ID" >&2; exit 2 ;;
esac
