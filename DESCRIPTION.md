`<upstream>224</upstream>

The Nest is the hosting platform for [Pijul](https://pijul.org), a distributed version control system
built on a sound theory of patches rather than on snapshots and three-way merges.

It gives a Pijul repository the things a repository needs once more than one person touches it: user
accounts, a web interface for browsing changes and file trees, discussions attached to a repository,
cloning over HTTPS, and push over SSH.

## Why Pijul rather than Git

Pijul's model is commutative. Two changes that do not touch the same lines can be applied in either
order and produce the same repository, which means a change can be pulled from one branch into
another without rebasing, cherry-picking, or the merge conflicts those produce. Conflicts still
happen when two people genuinely edit the same thing, but they are represented in the repository
rather than resolved and forgotten, so a resolution can be revisited.

If you have wanted Darcs' theory with performance that does not fall over on a large repository, this
is that.

## What this package gives you

- The web interface, at your own domain
- Repository hosting with per-user accounts, public and private repositories
- Cloning over **HTTPS**, working immediately with no port configuration
- Pushing over **SSH**, on a port you choose at install time — the Nest's HTTPS surface is
  clone/read only; pushing a change requires SSH
- Discussions and change review
- Outgoing email through the Cloudron mail relay, for password recovery and notifications

## What is deliberately turned off

The Nest is the software that runs Pijul's own hosted service, so it carries features that only make
sense there. This package disables them:

- **Billing.** No Stripe keys, no paid tier, no pricing page.
- **CI.** The job runner is not configured, and no CI endpoints are registered.
- **Zulip notifications.**

Private repository and storage quotas, which default to zero on the hosted service, are raised to
values that make sense for a self-hosted instance.

## Accounts

The Nest has its own account system with its own password handling. It does **not** support Cloudron
single sign-on: there is no OIDC or LDAP support upstream to map onto. Users register on the instance
itself. The first account you create is yours to administer with.

Cloudron's `proxyAuth` is deliberately not used. It would gate the whole HTTP surface, which for a
version control system means breaking every push and pull.

## Status

Pijul and the Nest are pre-release software. Upstream does not tag releases, so this package pins an
exact upstream change and records it in the changelog. The version number belongs to the package, not
to the Nest.