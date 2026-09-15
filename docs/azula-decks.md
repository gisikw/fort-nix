# Azula decks sharing origin

`decks.gisi.network` is a second origin over the **same** generated Slidev
tree that `slides.gisi.network` publishes (`/home/familiar/Projects/slides/public`),
with a different wall. `slides.<domain>` stays identity-gated (`admin`) and is
untouched; `decks.<domain>` exists so an individual deck can be shared with
ASG colleagues who have no Fort identity. This is option 2 from
[azula-slides.md](azula-slides.md#access-boundary).

It is reusable (the allow-list is a Nix list) but currently publishes exactly
one deck: `asg/opco-ai-efficiency`.

## URL shape

| Request                                    | Anonymous | `viewer` + correct password                                  |
| ------------------------------------------ | --------- | ------------------------------------------------------------ |
| `/asg/opco-ai-efficiency/`                 | `401`     | `200` — `<root>/asg/opco-ai-efficiency/index.html`            |
| `/asg/opco-ai-efficiency`                  | `401`     | `301` to `/asg/opco-ai-efficiency/`                           |
| `/asg/opco-ai-efficiency/assets/app.css`   | `401`     | `200`, the nested asset verbatim                              |
| `/asg/opco-ai-efficiency/3` (deep link)    | `401`     | `200`, that deck's own `index.html` (SPA fallback)            |
| `/asg/opco-ai-efficiency/slides.md`        | `401`     | `404` (explicit Markdown refusal)                             |
| `/asg/opco-ai-efficiency/assets/`          | `401`     | `403` (no autoindex)                                          |
| `/asg/opco-ai-efficiencyX/`                | `404`     | `404`                                                         |
| `/asg/other-deck/`, `/asg/`, `/`, `/index.html` | `404` | `404` — nothing outside the allow-list exists on this origin |
| `/asg/opco-ai-efficiency/../other-deck/`   | `404`     | `404` — nginx normalizes `$uri` before location matching      |
| wrong password, or any user other than `viewer` | —    | `401`                                                         |

Verified against nginx 1.28.2 (the package this host's unit runs) with a
minimal reproduction of the two locations; the table is observed status codes.

## How it is built

One `fort.cluster.services` entry (gated, see below):

```nix
{
  name = "decks";
  staticRoot = slidesPublicRoot;   # same tree as slides
  visibility = "public";
  sso.mode = "none";               # the wall is written into the locations
  health.enabled = false;          # a probe could only ever see 401/404
}
```

`sso.mode = "none"` is **not** an open origin. The vhost's `/` location gets
`return 404;` — a rewrite-phase directive, so it fires before `try_files` and
before any auth: everything outside the allow-list is a flat 404 with no
credential prompt. Each published deck is a regex location
(`~ ^/asg/opco-ai-efficiency(/|$)`), which outranks `/`, and carries:

```nginx
auth_basic "Restricted";
auth_basic_user_file /run/secrets/decks-htpasswd;
if ($uri ~* "\.(md|markdown)$") { return 404; }
index index.html;
autoindex off;
try_files $uri $uri/ /asg/opco-ai-efficiency/index.html =404;
```

`auth_basic` is the access phase, so it precedes `try_files`, the
trailing-slash `301` and the SPA fallback alike. The fallback path is a
literal inside the deck's own prefix, so a deep link can never resolve into a
neighbouring deck. TLS, certificates, public-ingress proxy need, Headscale and
CoreDNS DNS needs all derive from the service entry by the normal mechanism.

Logging: a dedicated `decks_safe` access log (`$time_iso8601 $remote_addr
"$request_method $uri" $status $body_bytes_sent` — no `$remote_user`, no
query string, no headers) and a dedicated error log pinned at `warn`
(debug-level nginx errors can dump request headers, i.e. the Basic
credential). A password mismatch logs the username only.

## The secret

- Nix option: `sops.secrets.decks-htpasswd`
- Encrypted file (expected path): `clusters/bedlam/hosts/azula/decks-htpasswd.sops`
- `.sops.yaml` creation rule: already present for that path (admin, ci,
  dev-sandbox principals + the azula device key — same recipients as
  `work-laptop-tiamat-router-token.sops`).
- Runtime path: `/run/secrets/decks-htpasswd`, `format = "binary"`, owner
  and group = the nginx user, mode `0400`. nginx opens
  `auth_basic_user_file` per request, so rotating the secret takes effect at
  the next activation with no reload.
- Contents: **exactly one line**, `viewer:<hash>`. The username is fixed.
  bcrypt, apr1 and sha-crypt (`$5$`/`$6$`) all work: this nginx links
  libxcrypt 4.5.2. Prefer bcrypt.

### Creating it (do this once, locally, never on the host)

```sh
cd fort-nix
nix shell nixpkgs#apacheHttpd nixpkgs#sops -c sh -c '
  htpasswd -nB viewer \
    | SOPS_AGE_KEY_FILE=~/.config/age/keys.txt \
      sops --input-type binary --output-type json \
        --filename-override clusters/bedlam/hosts/azula/decks-htpasswd.sops \
        -e /dev/stdin > clusters/bedlam/hosts/azula/decks-htpasswd.sops'
git add clusters/bedlam/hosts/azula/decks-htpasswd.sops
```

`htpasswd -nB` prompts for the password on the terminal and writes only the
hash to stdout; the cleartext exists nowhere but your terminal and the
message you send to the colleague. `--filename-override` is what makes sops
pick the creation rule when reading from stdin. Rotate with
`just edit-secret clusters/bedlam/hosts/azula/decks-htpasswd.sops` (paste a
fresh `htpasswd -nB viewer` line) or by re-running the pipeline above.

Never: commit the cleartext, put it in a Nix expression (it would land in the
world-readable store), pass it on a command line on the host, or paste it into
a ticket/commit message.

### Fail-closed gating until it exists

Flake sources exclude untracked files, and sops-nix hashes every `sopsFile`
at evaluation time, so a declared-but-missing secret would break evaluation
of the whole host (and with it `just rekey`, `just test`, GitOps). Instead the
manifest gates the **entire** decks surface — service entry, vhost, log
format, secret, verifier — on `builtins.pathExists ./decks-htpasswd.sops`.
While the file is absent, evaluation emits a `warnings` entry naming the
expected path and nothing is generated: no vhost, no DNS, no ingress. The
shape-level assertions (allow-list, fixed username, log format, slides
untouched) are checked regardless; the vhost-level ones apply once the file
is present.

### Runtime verifier

`decks-htpasswd-verify.service` runs as the nginx user after `sops-nix.service`
and before `nginx.service`. It checks the decrypted file is readable by nginx,
has exactly one line, and that line is `viewer:<hash>` with a recognised hash
prefix. It never prints file contents. It is deliberately **not** a
`Requires=` of nginx: the wall already fails closed (nginx answers `401` to
anything it cannot match), and this host's other vhosts must not go down over
one htpasswd line. A failure shows up in the journal, not as an outage.

## Filesystem boundary

Identical to slides, by construction: the vhost root is the same
`public/` tree, nginx keeps `ProtectHome = tmpfs` and binds only
`-/home/familiar/Projects/slides/public` read-only. Nothing about the
repository directory, `.git`, `node_modules` or the Markdown sources enters
nginx's namespace; the deck location additionally refuses `*.md`.

## Adding another deck

Append its root-relative prefix to `decksPublished` in the manifest **and**
update the pinning assertion (`decksPublished == [ ... ]`). That is
deliberate: widening a password-shared surface should be a reviewed change.
Every entry gets its own regex location with the same wall; the shared
`viewer` credential unlocks all of them, so if two audiences must not see
each other's decks, add a second origin with its own secret rather than a
second entry here.

## Evaluation assertions

In `clusters/bedlam/hosts/azula/manifest.nix`, prefixed `decks:` (plus one
new `slides:` guard):

Always:

1. name is `decks`, user is `viewer`, allow-list is exactly
   `[ "asg/opco-ai-efficiency" ]`, slugs are safe and unique.
2. the htpasswd path is `/run/secrets/decks-htpasswd`, not under `/nix/store`,
   and no `viewer:` credential line appears in any Nix-rendered config.
3. the access log format is the credential-safe one (no `$remote_user`,
   `$http_*` or raw `$request`).
4. the verifier pins `^viewer:` and never `cat`s or echoes the file.
5. `slides.<domain>` has no `auth_basic` anywhere and its service entry is
   still `identity` / `[ "admin" ]`.

When the secret is present:

6. vhost root is the slides output tree, TLS forced, `sso.mode = "none"`, no
   VPN/LAN bypass, health off.
7. nginx still binds only the public tree with `ProtectHome = tmpfs`.
8. the location set is exactly `/` (unconditional `return 404`, no auth) plus
   one regex location per published deck.
9. every deck location carries `auth_basic "Restricted"`,
   `auth_basic_user_file <secret.path>`, the in-prefix `try_files` fallback,
   the Markdown refusal, `index index.html`, `autoindex off`, and never
   `auth_basic off`.
10. nothing on the vhost renders `autoindex on`, `auth_request`, `_identity`,
    `proxy_pass`, `alias` or a `root` override.
11. the vhost uses the `decks_safe` access log, a `warn`-level error log, and
    never `debug`; the `log_format` is present in `commonHttpConfig`.
12. the secret is this host's binary SOPS file at the expected path, `0400`,
    owned by the nginx user and group.
13. the verifier runs as the nginx user, after `sops-nix.service`, before
    `nginx.service`, and is not in nginx's `Requires`/`BindsTo`/`Wants`.

## Activation caveats

- Until the secret is committed, activation is a no-op for this feature (see
  gating above). Once it is, DNS for `decks.<domain>` follows automatically via
  the control plane after the host activates.
- The deck must be built with Slidev's base set to
  `/asg/opco-ai-efficiency/` so its assets resolve under that prefix (the same
  requirement `slides.<domain>` already has). Nothing in this repo touches
  the deck or slides repository.
- Deployment was not performed as part of this change; nothing was applied
  and no nginx reload was issued.
