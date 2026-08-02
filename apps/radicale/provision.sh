# Provision Radicale collections from an encrypted manifest.
#
# Idempotent and additive-only: creates collections that are missing and
# true-ups displayname/colour on every run. It never deletes a collection and
# never touches the objects inside one - a provisioner that can delete is a
# provisioner that can silently eat the family calendar on a bad manifest.
#
# Collection *names* are the sensitive part here (they are the kids' names), so
# the manifest is sops-encrypted and only ever read from /run/secrets.
#
# Env (set by the systemd unit):
#   MANIFEST  path to decrypted JSON manifest
#   PASSFILE  path to the owning principal's plaintext password
#   BASE      radicale base URL (loopback)
set -euo pipefail

PASS="$(tr -d '\n' < "$PASSFILE")"
OWNER="$(jq -r '.owner' "$MANIFEST")"
AUTH="$OWNER:$PASS"

req() { # method path [data] -> prints status code, body to /dev/null
  local method=$1 path=$2 data=${3:-}
  if [[ -n "$data" ]]; then
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'Content-Type: application/xml; charset=utf-8' \
      -u "$AUTH" "$BASE$path" --data-binary "$data"
  else
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'Depth: 0' -u "$AUTH" "$BASE$path"
  fi
}

# Wait for radicale to accept authenticated requests. after=/requires= only
# guarantees the unit started, not that the HTTP listener is up.
ready=""
for _ in $(seq 1 30); do
  if [[ "$(req PROPFIND "/$OWNER/" || true)" == "207" ]]; then ready=1; break; fi
  sleep 1
done
[[ -n "$ready" ]] || { echo "radicale did not become ready" >&2; exit 1; }

created=0 updated=0

while read -r row; do
  path=$(jq -r '.path'         <<<"$row")
  name=$(jq -r '.displayname'  <<<"$row")
  kind=$(jq -r '.kind'         <<<"$row")   # calendar | addressbook
  color=$(jq -r '.color // ""' <<<"$row")
  comps=$(jq -r '(.components // []) | map("<C:comp name=\"" + . + "\"/>") | join("")' <<<"$row")

  status=$(req PROPFIND "$path" || true)

  if [[ "$status" == "404" ]]; then
    if [[ "$kind" == "addressbook" ]]; then
      body="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<D:mkcol xmlns:D=\"DAV:\" xmlns:CR=\"urn:ietf:params:xml:ns:carddav\"><D:set><D:prop>
<D:resourcetype><D:collection/><CR:addressbook/></D:resourcetype>
<D:displayname>$name</D:displayname>
</D:prop></D:set></D:mkcol>"
      rc=$(req MKCOL "$path" "$body")
    else
      body="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<C:mkcalendar xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:set><D:prop>
<D:displayname>$name</D:displayname>
<C:supported-calendar-component-set>$comps</C:supported-calendar-component-set>
</D:prop></D:set></C:mkcalendar>"
      rc=$(req MKCALENDAR "$path" "$body")
    fi
    if [[ "$rc" != "201" ]]; then
      echo "FAIL create $path -> $rc" >&2
      exit 1
    fi
    echo "created $path ($kind)"
    created=$((created + 1))
  elif [[ "$status" != "207" ]]; then
    echo "FAIL probe $path -> $status" >&2
    exit 1
  fi

  # True-up presentation on every run so the manifest stays authoritative.
  # Radicale permits PROPPATCH of the component set even though RFC4791 marks
  # it protected; we deliberately do not use that - changing a live
  # collection's component set is a data-shape change, not presentation.
  colprop=""
  [[ -n "$color" ]] && colprop="<ICAL:calendar-color>$color</ICAL:calendar-color>"
  body="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<D:propertyupdate xmlns:D=\"DAV:\" xmlns:ICAL=\"http://apple.com/ns/ical/\"><D:set><D:prop>
<D:displayname>$name</D:displayname>$colprop
</D:prop></D:set></D:propertyupdate>"
  rc=$(req PROPPATCH "$path" "$body")
  if [[ "$rc" != "207" ]]; then
    echo "FAIL proppatch $path -> $rc" >&2
    exit 1
  fi
  updated=$((updated + 1))
done < <(jq -c '.collections[]' "$MANIFEST")

echo "radicale-provision: $created created, $updated true-upped"
