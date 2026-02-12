---
id: fort-cy6.2
status: closed
deps: [fort-cy6.1]
links: []
created: 2025-12-27T23:49:27.524565897Z
type: task
priority: 2
parent: fort-cy6
---
# Configure Forgejo SSO via pocket-id

Configure Forgejo to authenticate via pocket-id (the existing OIDC provider).

## Context
pocket-id is already deployed on drhorrible and provides OIDC authentication backed by LLDAP. Forgejo needs to be configured as an OIDC client.

## Implementation

### Register Forgejo as OIDC client in pocket-id
Add Forgejo client configuration to pocket-id. The redirect URI will be:
`https://git.gisi.network/user/oauth2/pocket-id/callback`

### Configure Forgejo OIDC
Update `apps/forgejo/default.nix` to add OIDC settings:

```nix
services.forgejo.settings = {
  # ... existing settings ...
  
  oauth2_client = {
    ENABLE_AUTO_REGISTRATION = true;
    USERNAME = "preferred_username";  # or "email"
    ACCOUNT_LINKING = "auto";
  };
};
```

The actual OIDC provider configuration may need to be done via Forgejo admin UI or database seeding, since it includes secrets (client_id, client_secret).

### Secrets
- Create `apps/forgejo/oidc-secret.age` with the OIDC client secret

## Acceptance Criteria
- [ ] Users can log in to Forgejo via pocket-id
- [ ] No local registration (SSO-only)
- [ ] User accounts auto-created on first login

## Notes
- May need to configure group-based authorization later
- Consider admin user bootstrapping strategy

Labels: [forgejo phase-1 sso]


