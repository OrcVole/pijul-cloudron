# Pijul Nest for Cloudron

A [Cloudron](https://cloudron.io) package for the **Pijul Nest**, the repository hosting platform for
the [Pijul](https://pijul.org) version control system.

Pijul is a distributed version control system built on a theory of patches. Self-hosting a bare Pijul
repository needs no server software at all, so there is nothing to package there. The Nest is the
part that needs hosting: accounts, a web interface, discussions, and push and pull over HTTPS and SSH.

Cloudron already offers Forgejo, Gogs and GitLab, and **none of them host Pijul repositories**, so
this fills a real gap rather than duplicating one.

## Install

Not yet published to the community app store. Until then:

```
cloudron install --image ghcr.io/orcvole/pijul-cloudron:<tag>
```

Choose an SSH port during install, or leave it disabled and use HTTPS.

## How the container is put together

Three processes under supervisor, plus a periodic job:

| Process | What it is | Port |
| --- | --- | --- |
| `nginx` | front proxy, the only thing Cloudron talks to | 8000 |
| `nest-api` | the Rust binary, serving HTTP and SSH itself | 5000, 2222 |
| `nest-ui` | the SvelteKit front end under node | 5050 |
| `nest-rank` | PageRank over the repository graph, every six hours | — |

**The nginx layer is load bearing and not a stylistic choice.** Upstream splits one public hostname
across both application processes by path. `/api`, `/login`, `/register` and the `.pijul` clone paths
belong to the API; everything else belongs to the UI. Pointing Cloudron's `httpPort` straight at the
UI renders a perfect front page and makes signing in impossible, because the UI answers 404 for
`/login` while the API answers 405 to a GET on it.

Everything else — `/_app/`, the web fonts, `theme-init.js` — is served by adapter-node itself, so the
proxy does not alias any static path.

## What is disabled, and how

The Nest is the software behind Pijul's own hosted service, so it ships features that only make sense
there. All three are nullable upstream and all three are off:

| Feature | How |
| --- | --- |
| Stripe billing | no `[stripe]` section, no `STRIPE_*` in the environment |
| CI job runner | `ci.url = []`, no `ci.filesystem`, so `PUBLIC_JOBS_ENABLED` is never exported |
| Zulip notifications | no `[zulip]` section |

Private repository and storage quotas default to **zero** upstream, which is a hosted-service default
that would give a self-hosted instance's users no private repositories at all. They are raised here.

## Single sign-on

Not supported, deliberately. Upstream authentication is the application's own, with PBKDF2 in
process; there is no OIDC or LDAP to map Cloudron's addons onto. `proxyAuth` is the wrong answer for
a version control system, because it gates the whole HTTP surface and that means breaking push.

## Versioning

The Nest is neither versioned nor released upstream, so the package version is the package's own and
each release records the exact upstream change hash it was built from. See
[docs/decisions/0001-versioning.md](docs/decisions/0001-versioning.md).

## Licence

Upstream is AGPL-3.0-or-later, which the Nest's README calls "highly unlikely to change". This
package ships unmodified upstream code and is licensed the same way. See [LICENSE](LICENSE).

Upstream is funded by NGI Zero Core and NLnet with European Commission support.

The bundled web fonts, Iosevka Term and Terminus, are both SIL Open Font License 1.1, and their
licence texts ship beside them in the image.

## Documentation

- [docs/decisions/](docs/decisions/) — architecture decisions, numbered
- [docs/PACKAGING-NOTES.md](docs/PACKAGING-NOTES.md) — what is verified and what is assumed
- [docs/DEBUGGING.md](docs/DEBUGGING.md) — gate evidence and how to reproduce it
- [docs/FOR-CLOUDRON.md](docs/FOR-CLOUDRON.md) — observations for the Cloudron team
- [docs/FOR-UPSTREAM.md](docs/FOR-UPSTREAM.md) — what would make the Nest easier to package

## A note on contributions to upstream

Pijul's `CONTRIBUTING.md` says they may reject patches created automatically by linters or LLMs. This
package therefore sends **nothing** upstream from its tooling. Anything in `docs/FOR-UPSTREAM.md` is
written down for a human to raise, or not at all.
