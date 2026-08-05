### Create your account

The Nest has its own accounts and does **not** use Cloudron single sign-on, because upstream provides
no OIDC or LDAP to map onto. Visit your new instance and register. The first account you create is
yours.

### Cloning and pushing

**Cloning over HTTPS** works immediately, no SSH needed:

```
pijul clone https://<your-domain>/<user>/<repo>
```

**Pushing needs SSH.** The Nest's HTTPS surface is read only: browsing, cloning, and reading
private repositories you are authenticated to, but not accepting a push. To push a change, clone
and push over SSH instead, on the port you chose during install:

```
pijul clone ssh://<user>@<your-domain>:<port>/<user>/<repo>
pijul push
```

The Nest serves SSH itself rather than through the system's own SSH daemon, which is why it cannot
use port 22. If you leave the SSH port disabled, you can browse and clone but cannot push to this
instance at all — enable it if you intend to use this as a real remote rather than a read-only mirror.

Add your public key under your account settings before pushing over SSH.

### Things worth knowing

- **Billing, CI and Zulip notifications are turned off.** They exist upstream because the Nest is the
  software behind Pijul's own hosted service.
- **Your SSH host key and password-hashing material are generated once, on first run**, and kept in
  the app's data directory. They are included in Cloudron backups. Restoring a backup restores them,
  so clients do not see a changed host key and existing passwords keep working.
- **Pijul and the Nest are pre-release software.** Upstream tags no releases, so this package pins an
  exact upstream change, recorded in the changelog. The version number on this app describes the
  package rather than the Nest.
