# Development

## Layout

| Path | Content |
|---|---|
| `compose.yaml`, `init.sh`, `.env.example`, `acme.env.example`, `sadm-config.yaml` | What a host needs |
| `compose.build.yaml` | Builds the image locally instead of pulling it |
| `docker/Dockerfile` | The image: Debian, Samba from backports, BIND, supervisord, certbot, SADM agent |
| `docker/bin/` | Commands of the image: `entrypoint.sh` (start, provision, join, check), `diagnose`, `backup`, `restore-gpo-folders`, `healthcheck`, `letsencrypt.sh` |
| `docker/lib/common.sh` | Settings with their defaults, checks, messages |
| `docker/lib/render-template` | Writes a file from a Jinja template |
| `docker/templates/` | Jinja templates of `smb.conf` and `named.conf`, written at every start |
| `docker/supervisor/` | Programs of supervisord |
| `tests/smoke-test.sh` | Sets up a test domain with an image and checks it |
| `docs/`, `mkdocs.yml` | This documentation |
| `.github/workflows/` | Build, checks, releases, documentation |
| `.release/` | Notes of the next release |

Design rules:

- **Logic lives in the image**, not on the host: an image update brings
  fixes along without new files on the host. `init.sh` only guides through
  the setup.
- **The text of a generated file lives in its template.** `entrypoint.sh`
  only finds the values the templates need (e.g. `TLS_SOURCE`, `DLZ_MODULE`);
  the templates see every setting of `.env` by its name.
- **Every default is set once**, in `load_settings` in `docker/lib/common.sh`.
  `.env` and the container use the same names.
- **Samba and BIND keep their defaults** unless a setting is needed and
  commented in the template, so that their updates take effect.
- **Every error says what to do**, with `fail` and a link into
  `troubleshooting.md`.

## Build and test locally

```sh
docker compose -f compose.yaml -f compose.build.yaml build
tests/smoke-test.sh ghcr.io/stefgo/samba-ad:latest
```

The smoke test provisions `SMOKE.TEST` in a Docker network of its own,
starts the domain controller, waits for the health check and runs
`diagnose`, Kerberos, LDAP and a backup. It removes everything afterwards;
`KEEP=1` keeps the container for a closer look.

The documentation:

```sh
pip install -r docs/requirements.txt
mkdocs serve
```

## Image

GitHub Actions builds the image for `linux/amd64` and `linux/arm64`, each on
a native runner, and publishes it to `ghcr.io/stefgo/samba-ad`. No tag is set
until the smoke test passed on both architectures.

| Tag | Content |
|---|---|
| `latest` | The last release |
| `X.Y.Z`, `X.Y` | A release; use it to pin or roll back |
| `main` | The main branch, built on every change below `docker/` or `tests/` |
| `sha-<commit>` | One commit of main |

Every Monday the last release is rebuilt with the current Debian and Samba
packages under the same tags (`rebuild.yml`). `latest` therefore moves with
a release and with the weekly rebuild, never with a push to main. A nightly
job prunes untagged and old `sha-*` images.

The SADM agent comes from `ghcr.io/stefgo/sadm-client:main`
(`SADM_CLIENT_TAG` in the Dockerfile); pin it to a release tag once
sadm-client publishes releases. Dependabot proposes updates of the GitHub
Actions and of the documentation tools.

## Checks

`ci.yml` runs on every push and before a release: shellcheck, hadolint,
`docker compose config` with `.env.example`, and `mkdocs build --strict`,
which fails on broken links.

## Releases

A release is created by hand with the shared workflow of
[stefgo/release-workflows](https://github.com/stefgo/release-workflows):

1. Describe what is new in `.release/next.md` and commit it. A release
   without this text is refused.
2. Run **Create Release** in the Actions tab with `dry_run` on: the summary
   shows the next version and the notes.
3. Run it again with `dry_run` off. It creates the tag, the GitHub release
   and the entry in `CHANGELOG.md`, empties `.release/next.md` and builds the
   image for the new tag.

The version follows the commit messages, which use
[Conventional Commits](https://www.conventionalcommits.org/): `feat:` raises
the minor position, `fix:`, `perf:` and `revert:` the patch position. A hook
checks the format; activate it once per clone:

```sh
git config core.hooksPath .githooks
```

## Documentation

`docs.yml` publishes `docs/` to GitHub Pages on every change on main
(Settings → Pages → Source: GitHub Actions).
