# Azula slides publishing surface

`slides.gisi.network` publishes Kevin's Slidev workspace as **generated files
only**. It is the same idiom as the neighbouring `wireframes` vhost: a
`fort.cluster.services` entry with a `staticRoot`, plus the bind mount nginx
needs because its unit runs with `ProtectHome`. There is no unit, no build step
run by Nix, and no relationship to Familiar Presence.

## URL shape

| Request                                | Served from                                                        |
| -------------------------------------- | ------------------------------------------------------------------ |
| `/asg/<deck>/`                         | `/home/familiar/Projects/slides/public/asg/<deck>/index.html`       |
| `/asg/<deck>`                          | `301` to `/asg/<deck>/`                                             |
| `/asg/<deck>/assets/app.css`           | the nested asset, verbatim                                          |
| `/asg/<deck>/3` (Slidev history route) | that deck's own `index.html` (SPA fallback, never another deck's)   |
| `/asg/<deck>/slides.md`                | `404` (explicit Markdown refusal)                                   |
| `/asg/<deck>/assets/` (no index)       | `403` (autoindex is off everywhere on this vhost)                   |
| `/asg/unknown-deck/`                   | `404`                                                               |
| `/`                                    | `403`/`404` — no autoindex, no root index is published today        |
| `..` traversal                         | `400` — nginx normalizes `$uri` before the location match           |

Verified against nginx 1.28.2 (the exact package this host's nginx unit runs)
with a minimal reproduction of the two locations; the table above is the
observed status codes, not a prediction.

## Registration

The vhost, TLS material, public-ingress proxy need, Headscale DNS need and
CoreDNS DNS need are all derived by the normal mechanism from one entry:

```nix
{
  name = "slides";
  staticRoot = slidesPublicRoot;   # /home/familiar/Projects/slides/public
  visibility = "public";
  sso = { mode = "identity"; groups = [ "admin" ]; };
  health.enabled = false;
}
```

Nothing about certificates or DNS is hand-rolled. `health.enabled = false` is
the one deliberate deviation from the defaults: the identity wall answers a
Gatus probe with `302`, and the tree is legitimately empty until a deck has
been built, so a health check could only ever be a false alarm. (`familiar-ui`
disables health for the same class of reason.)

## Access boundary

- Identity SSO, `groups = [ "admin" ]`. That is the most restrictive wall that
  still lets Kevin in, chosen because deck material may be confidential ASG
  work product. `wireframes` uses `admin` + `infra`; slides deliberately does
  **not** include `infra`.
- Both content locations carry `auth_request /_identity/validate`. The
  per-deck location is a regex location, which outranks the generic `/` prefix
  location, so it restates the wall rather than inheriting it — an assertion
  pins that it is present in both.
- **To share a deck with ASG colleagues who are not in Kevin's identity
  groups**, one of these must change (none of them is implied by this commit):
  1. add those people to an identity group and add that group to
     `sso.groups` (preferred: still authenticated, still auditable); or
  2. add a second `fort.cluster.services` entry with a different subdomain and
     a narrower `staticRoot` (e.g. a per-deck published directory) at a weaker
     `sso.mode`; or
  3. relax this entry to `sso.mode = "none"`, which makes every deck in
     `public/` world-readable on the internet and should not be done for a
     shared root.
  Do not "temporarily" widen `sso.groups` on this entry: the wall is per
  vhost, so it applies to every deck under `public/` at once.

## Filesystem boundary

- `nginx.serviceConfig.ProtectHome = "tmpfs"` (host-wide, pre-existing) plus
  `BindReadOnlyPaths = [ ".../wireframes" "-.../slides/public" ]`. Only the
  generated `public/` tree enters nginx's namespace: not the repository root,
  not `.git`, not `node_modules`, not the `.md` sources, not `/home/familiar`.
- tmpfiles:
  - `d /home/familiar/Projects/slides 0711 familiar users -` — exists and is
    owner-traversable only. Sources and history stay unreadable to other local
    accounts; nginx never needs this directory, because inside its namespace
    the path above the bind mount is systemd's tmpfs.
  - `d /home/familiar/Projects/slides/public 0755 familiar users -` — the
    minimum for the nginx worker (a different uid) to traverse the tree and
    read the `0644` files a Slidev build emits. Nothing else on this host is
    relaxed; in particular `/home/familiar` itself remains untraversable.
- Source Markdown cannot be served: it is outside the bind mount, and the deck
  location additionally returns `404` for `*.md`/`*.markdown` in case a future
  build step copies sources into `public/`.

## Activation caveats

- **The checkout may not exist and may never have been built when Nix
  evaluates or activates.** Nothing in the evaluation reads the tree; the path
  is a plain string. At activation, systemd-tmpfiles creates both directories
  (before nginx starts), so the bind source always exists. As a second layer,
  the bind entry is written `-<path>`: if the directory were somehow missing,
  systemd skips the mount instead of failing the nginx unit, which serves every
  other vhost on this host.
- Until a deck is built, requests return `404`/`403`. That is the intended
  empty state, not a misconfiguration.
- `git clone` into the tmpfiles-created directory must use
  `git clone <url> .` from inside it (the directory already exists).
- If the repository directory already exists with a wider mode, activation
  tightens it to `0711`. Build output must land in `public/` with world-read
  bits (the default `umask 022` is fine).
- Publishing new decks needs no rebuild and no nginx reload: the vhost serves
  whatever is under `public/asg/`.
- Deployment/activation is out of scope for this commit; nothing here was
  applied, and no nginx reload was performed.

## Familiar Presence

This surface is completely unrelated to Familiar Presence. No unit is added or
modified besides `nginx.serviceConfig`; Presence gains no ordering, no
dependency, and no reference to the slides paths. An assertion checks that
Presence's unit relationships do not mention `nginx.service`, that its
`ExecStart`/`WorkingDirectory` do not mention the slides repository, and that
nginx neither orders after Presence nor carries a Presence restart trigger.

## Evaluation assertions

All in `clusters/bedlam/hosts/azula/manifest.nix`, prefixed `slides:`:

1. vhost `root` is exactly `/home/familiar/Projects/slides/public`.
2. every content location sits behind identity SSO, and the validation
   subrequest requires exactly the `admin` group.
3. nginx binds only the public tree read-only (never the repo dir or home) and
   keeps `ProtectHome = tmpfs`.
4. tmpfiles grant `0711` to the repository dir and `0755` only to `public/`.
5. no `autoindex on` anywhere on the vhost; both content locations set
   `index index.html` and `autoindex off`.
6. the per-deck fallback is exactly `try_files $uri $uri/ /asg/$deck/index.html
   =404` and the Markdown refusal is present.
7. the surface is unrelated to the Familiar Presence lifecycle.
