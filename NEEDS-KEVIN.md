# NEEDS-KEVIN — lordhenry cofferd + Sol/GPT credential cutover

Branch: `lordhenry-cofferd`. Touches only
`clusters/bedlam/hosts/lordhenry/manifest.nix` (plus this file). `origin/main`
is untouched — nothing here has been merged, deployed, or restarted.

## What this branch does

Brings cofferd up on lordhenry (it had none) and repoints tiamat's Sol/GPT
OpenAI Responses arms off the self-refreshing on-disk OAuth file
(`/var/lib/tiamat/openai_oauth.json`, expired) onto the local cofferd socket —
the same pattern lair already runs on ratched. Coffer-server (drhorrible) owns
OAuth rotation; tiamat becomes a pure reader that never refreshes.

Mirrors ratched's worked example:
- `coffer` overlay (`infra/coffer`, role `daemon`).
- `coffer` user/group; **tiamat pinned to uid 491** and added to the `coffer`
  group for socket reach.
- Trust anchor (`clusters/bedlam/coffer-server.crt` → `/etc/cofferd/server.crt`)
  and `cofferd/config.toml` with a `[[workload]] name = "tiamat"` peer-cred
  mapping (uid 491), prewarming `fort/openai/cred` with an empty `grant_shape`
  (cofferd files the grant request itself).
- `cofferd-mint-client-cert` oneshot minting the client cert from lordhenry's
  ssh host key (`--san lordhenry`).
- tmpfiles for `/var/lib/cofferd` and `/run/cofferd`.
- Sol/GPT arms (`exo-gpt`, `exo-gpt-sol`) flipped to
  `oauth_source: cofferd` + `oauth_secret_path: fort/openai/cred`.

## ⚠️ Open item — account id (`oauth_account_id`)

Left **unset** (documented placeholder comment in the profiles YAML). Reason:
coffer serves only the access token, but that token is a JWT carrying the
`account_id` claim, and tiamat extracts it into the `chatgpt-account-id`
header automatically (same mechanism as lair's usage collector). So Sol comes
back **without** you doing anything here.

I could not recover the literal id from lordhenry's expired
`/var/lib/tiamat/openai_oauth.json` — this work ran on the ratched dev-sandbox
and that file lives on lordhenry (no live cross-host reads per the brief).

Pin it explicitly **only if** the codex endpoint rejects the derived value.
Recover from that file's `account_id` field, or read it off `fort/openai/cred`
in coffer-web, then uncomment `oauth_account_id:` on both arms.

## Merge-then-click runbook

Everything below is convergence you approve, not commands you run on the host.

### 0. Merge timing
Merging triggers a gitops deploy on lordhenry, and **the tiamat overlay
restarts on deploy** — that drops any in-flight conversation. Merge **between
conversations** (Sol is already offline, so there's no rush; pick a quiet
moment). The tmpfiles `Z /var/lib/tiamat` rule re-chowns tiamat's state to the
newly-pinned uid 491 on activation, so the uid change does not orphan files.

1. **Merge `lordhenry-cofferd` → main.** Gitops deploys lordhenry.

2. **cofferd comes up and enrolls.** On first deploy `cofferd-mint-client-cert`
   mints the client cert from the host ssh key, then the cofferd overlay
   starts and calls home to coffer-server. In **coffer-web** lordhenry appears
   as a **PENDING** enrollment.
   - Verify: coffer-web shows a pending host named/keyed for lordhenry. If it
     doesn't appear within a few minutes, the overlay is likely crash-looping
     pre-cert — check its journal via `fort lordhenry journal` for
     `overlay-coffer-cofferd` and `cofferd-mint-client-cert`.

3. **Approve the host enrollment — eyeball the key first.** Compare the pinned
   client key/SPKI shown in coffer-web against lordhenry's real host key:
   `fort lordhenry read /etc/ssh/ssh_host_ed25519_key.pub` (or the SPKI coffer
   derives from it). They must match — that TOFU pin ties the client cert to
   host identity. Approve only on a match.

4. **The tiamat grant request appears.** Once enrolled, cofferd files the
   `fort/openai/cred` grant for the `tiamat` workload (from `grant_shape`). It
   shows up in coffer-web **awaiting approval**. Approve it (read verb,
   `fort/openai/cred`, workload `tiamat`).
   - Verify: after approval, `/var/lib/cofferd/grants/tiamat.grant` exists and
     cofferd's journal shows the secret prewarmed/delivered.

5. **Sol/GPT comes back.** Tiamat reads the token from the socket on the next
   dispatch to the `exo-gpt` / `exo-gpt-sol` profiles. No tiamat restart is
   needed for the credential itself (it reads per-dispatch), but the deploy in
   step 1 already restarted it with the new profiles.
   - Verify: route a turn to `exo-gpt-sol`. On success tiamat logs
     `tiamat_openai_responses_dispatch ... auth_mode=oauth` followed by
     `tiamat_openai_responses_result ... status=completed`.
   - If it 401s: tiamat logs `tiamat_openai_responses_cofferd_reread` (its one
     re-read+retry), then a `backend_http_error` whose message names
     `coffer-server owns rotation of secret "fort/openai/cred"`. That means the
     served token is stale/rejected — a coffer-server rotation issue, not a
     tiamat one. Check that `fort/openai/cred` is live and rotating in
     coffer-web; tiamat does not (and must not) refresh it.

## Rollback

Revert the merge. tiamat's Sol arms fall back to `oauth_token_file` (still on
disk, though expired). cofferd on lordhenry becomes inert. No data migrated;
nothing destructive.
