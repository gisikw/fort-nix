# Azula `/private` router locality activation

This is the operational boundary for the terminal-only Familiar `/private`
mode. It classifies exactly one durable router provider row:

- provider: `llama-frankenstein`
- kind: `api-key`
- preset: absent
- base URL: `https://llama.gisi.network/v1`
- locality: `local`
- pinned address: `100.101.0.18`

The hostname remains necessary for HTTP Host and TLS certificate identity. The
router's reviewed private transport dials the address pin without DNS. DNS is
**not** authority for this boundary: a changed mesh address requires an
explicit reviewed Fort change, even if `llama.gisi.network` resolves to the new
address.

## Activation behavior

`tiamat-router-private-locality.service` is an idempotent oneshot running as
`tiamat-router`. It is ordered after bootstrap provisioning and is required by,
and ordered before, `overlay-tiamat-router.service`.

Before touching the database, it requires the overlay unit's configured binary
(and any currently running binary) to be the reviewed immutable store artifact
whose `version` is `eeee5f4`. Because the classification unit is `PartOf=` the
overlay service, every overlay stop/restart stops it and the next overlay start
must pass the binary and database gates again. An old or different router
therefore cannot start with the persisted local claim.

The SQL takes a SQLite `BEGIN IMMEDIATE` lock with a five-second busy timeout.
It accepts only either:

1. the exact expected row with both locality fields absent, changing exactly
   one provider row and the one `catalog_modified` metadata row; or
2. the same row already in the exact desired state, changing neither row.

Any missing row, changed kind/preset/base URL, malformed/intermediate locality,
extra pin, duplicate/missing catalogue metadata, lock timeout, ownership/mode
change, or unexpected affected-row count fails closed. The SQL never selects,
decrypts, copies, or updates `credential`. Provider and catalogue timestamps
change together only when effective catalogue state changes.

Inspect without exposing protected configuration:

```sh
sudo systemctl status tiamat-router-private-locality.service \
  overlay-tiamat-router.service
sudo journalctl -u tiamat-router-private-locality.service --no-pager
```

## Rollback

The emergency rollback unit conflicts with the overlay and activation units,
so the router is stopped before classification is removed:

```sh
sudo systemctl start tiamat-router-private-locality-rollback.service
```

It conditionally removes only `locality` and `localAddresses` from the same
exact provider and updates provider/catalogue timestamps. It accepts an
already-absent state idempotently and fails on every other state. It does not
read or modify credentials or any other provider configuration.

The active Fort configuration requires the classification unit, so leave the
router stopped, revert/remove this activation in Fort, deploy that revert, and
then verify the provider surface reports `locality:"remote"`. Merely restarting
the overlay before deploying the Fort revert intentionally re-applies the
reviewed classification.

## Privacy verification scope

Before allowing a new Familiar birth to use `/private`, verify all of the
following:

1. the provider surface contains `kind:"api-key", locality:"local"` and omits
   base URL and credential fields;
2. a synthetic locality-required request succeeds;
3. no router capture file contains its synthetic canary; and
4. llama/vLLM and reverse-proxy logs contain no prompt/request body.

Ordinary metadata access logs (method, normalized path, status, byte counts,
timing, request ID) are acceptable. Prompt or response body retention is not.
Do not claim prompt privacy if application defaults or observed logs retain
bodies. Activation does not restart Familiar Presence/Pi; `/private` becomes
usable only after the operator deliberately starts a new birth.
