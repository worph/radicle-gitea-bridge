# radicle-gitea-bridge

CI for [Radicle](https://radicle.dev) repositories, using [Gitea Actions](https://docs.gitea.com/usage/actions/overview).

A developer pushes to Radicle — a branch or a signed release tag. The bridge copies that
repository into Gitea with a real `git push`, and Gitea Actions runs its GitHub-style
workflows: build, test, push an image to Gitea's registry.

```
git push rad main v1.2.3
  → radicle-node / radicle-httpd     the source of truth
  → radicle-gitea-bridge             this repository
  → Gitea + act_runner               .gitea/workflows/*.yml
  → gitea-<domain>/<owner>/<repo>:1.2.3
```

Part of IPCR, a decentralised forge: Radicle for code, Gitea Actions for builds, IPFS for
images. Store listings: `ipcr/apps/Radicle-Gitea-Bridge` (standalone) and
`ipcr/apps/IPCR-Forge` (everything in one app).

## How it works

Every `INTERVAL` seconds, for every repository the Radicle node seeds:

1. **Opt-in check.** Is `OPT_IN_PATH` (`.gitea/workflows` by default) present at the
   repository's head? Asked through radicle-httpd's tree endpoint, so repositories without
   CI are never fetched. Committing a workflow is the whole setup, as on GitHub.
2. **Gitea repository.** Created on first sight as `<GITEA_OWNER>/<name>`, private, with
   Actions on and issues, pull requests, wiki, projects and releases off: Radicle stays the
   one place people push and discuss.
3. **Fetch** from radicle-httpd's git endpoint into a bare cache repository.
4. **Push** to Gitea.

| Radicle ref | Gitea ref | |
| --- | --- | --- |
| `refs/heads/*` (canonical) | `refs/heads/*` | forced: Radicle's head is the truth |
| `refs/namespaces/<delegate>/refs/tags/*` | `refs/tags/*` | never forced |

Radicle has no shared `refs/tags/` by default: a tag lives under the identity that pushed it.
The bridge takes every delegate's tags and publishes those the delegates agree on.

### Safety rules

- **A tag is never moved.** If a tag already in Gitea points elsewhere, the push fails and is
  logged. An image version always maps to one commit.
- **Delegates must agree.** A tag two delegates point at different commits is skipped.
- **Only its own copies.** An existing Gitea repository is written to only if its
  description names the Radicle ID. Repositories made by hand are never touched.

### Why a push, not a Gitea pull mirror

Mirror syncs don't reliably start workflows with branch or tag filters (gitea#24824,
#24926), a mirror copies Radicle's tags to `refs/namespaces/…` where Gitea doesn't see a
tag, and mirrors poll at most every 10 minutes. A push has none of these problems.

## Image

`ghcr.io/worph/radicle-gitea-bridge` — `alpine/git` plus `curl` and `jq`, and two scripts:

| Command | What |
| --- | --- |
| `bridge` (default) | the loop above |
| `bridge-init` | one-time credential setup, run as an install step |

### `bridge`

| Variable | Default | |
| --- | --- | --- |
| `RAD_API` | `http://radicle-api:8080` | radicle-httpd |
| `GITEA_URL` | `http://gitea:3000` | Gitea, internal address |
| `GITEA_OWNER` | `gitea_admin` | account that owns the copies |
| `GITEA_TOKEN_FILE` | `/secrets/gitea-token` | written by `bridge-init`, re-read every pass |
| `OPT_IN_PATH` | `.gitea/workflows` | |
| `INTERVAL` | `30` | seconds between passes |
| `CACHE` | `/cache` | one bare repository per Radicle repository; disposable |
| `ONESHOT` | unset | set to run a single pass and exit |

### `bridge-init`

Signs in once as `GITEA_OWNER` with `GITEA_PASSWORD` (Gitea's token API accepts only a
password) and leaves:

| Token | Scopes | Where |
| --- | --- | --- |
| `radicle-gitea-bridge` | `write:repository`, `write:user` | `$SECRETS_DIR/gitea-token` (0600) |
| `actions-registry-push` | `write:package` | user-level Actions secret `REGISTRY_TOKEN` |
| `ipcr-import` (only if `IPCR_AUTH_FILE` is set) | `read:package` | `$IPCR_AUTH_FILE`, as `owner:token`, for an IPCR gateway's `IMPORT_AUTH_FILE` |

`write:user` is what creating a repository requires. The user-level secret applies to every
repository the account owns, so new copies can push images with no per-repository setup.
Actions' own `secrets.GITHUB_TOKEN` is refused by Gitea's registry. Safe to re-run: both
tokens are replaced.

## A workflow that publishes an image

```yaml
# .gitea/workflows/build.yml, in the Radicle repository
on:
  push:
    tags: ['v*']
jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Registry address
        id: registry
        run: echo "host=${GITHUB_SERVER_URL#https://}" >> "$GITHUB_OUTPUT"
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ steps.registry.outputs.host }}/${{ github.repository }}
          tags: |
            type=semver,pattern={{version}}
            type=raw,value=latest
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ steps.registry.outputs.host }}
          username: ${{ github.repository_owner }}
          password: ${{ secrets.REGISTRY_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

`ubuntu-latest` must map to an image with Node and the Docker CLI, e.g.
`docker.gitea.com/runner-images:ubuntu-latest` (the IPCR Gitea listing sets this).

## Releasing

Push a `vX.Y.Z` tag. The workflow runs ShellCheck, builds amd64 and arm64, and publishes
`X.Y.Z`, `X.Y` and the commit sha. Then bump the pinned version in the store listings.

## Limits

- Polling, not events: Radicle's node sends no webhooks. Radicle's CI broker reacts to node
  events but ships no container image; when it does, this becomes its adapter.
- Public repositories only: radicle-httpd serves nothing else.
- Repository names come from Radicle. Two Radicle repositories with the same name map to the
  same Gitea name; the second is skipped (it isn't the first one's copy).
