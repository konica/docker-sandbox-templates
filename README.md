# docker-sandbox-templates
To manage Docker Sandbox custom templates and build template images based on them

## Publishing the .NET template

`scripts/build-push.sh` builds `dotnet/` for `linux/amd64` and `linux/arm64` and
pushes it to `ghcr.io/konica/docker-sandbox-templates/dotnet`.

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin

scripts/build-push.sh                 # every supported tag
scripts/build-push.sh 10              # just one
scripts/build-push.sh --no-push       # build both platforms, publish nothing
scripts/build-push.sh --dry-run       # print the buildx commands
```

### Tags

| Tag | Meaning |
| --- | --- |
| `:10`, `:8` | The supported .NET LTS lines. These float — a rebuild moves them onto the latest servicing patch. |
| `:<tag>-<shortsha>` | Immutable, one per build. Pin a sandbox here, or roll back to it. |

There is no `:latest`: this namespace holds several templates at several
framework versions, so an unqualified tag would be ambiguous.

Scheduled rebuilds run against an unchanged commit, so CI passes
`IMMUTABLE_SUFFIX` to keep their immutable tag distinct
(`:10-abc1234-r20260915-42`).

### CI

`.github/workflows/build-push.yml` publishes both tags when a release is
published, on the 15th of each month (absorbing .NET servicing patches, which
ship on the second Tuesday), and on manual dispatch.

### Base image

`dotnet/Dockerfile` pins `docker/sandbox-templates:claude-code` by digest so a
rebuild can't silently pick up a different base. Refresh it deliberately:

```bash
docker buildx imagetools inspect docker/sandbox-templates:claude-code \
  --format '{{.Manifest.Digest}}'
```
