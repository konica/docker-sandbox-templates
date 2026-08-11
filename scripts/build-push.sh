#!/usr/bin/env bash
# Build the .NET sandbox template for every supported LTS tag and push it to GHCR.
#
# Each tag is published twice: the floating LTS tag (`:10`, `:8`), which moves as
# .NET servicing patches land, and an immutable `:<tag>-<shortsha>` that never
# moves, so a sandbox can be pinned or rolled back to an exact build.
#
# There is deliberately no `:latest` — this registry namespace holds several
# templates at several framework versions, so an unqualified tag would be
# ambiguous.
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CONTEXT_DIR="${REPO_ROOT}/dotnet"

# Every tag this template publishes, as "<tag>:<dotnet-install channel>".
readonly SUPPORTED_TAGS=(
    "10:10.0"
    "8:8.0"
)

IMAGE="${IMAGE:-ghcr.io/konica/docker-sandbox-templates/dotnet}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
SOURCE_URL="${SOURCE_URL:-https://github.com/konica/docker-sandbox-templates}"
BUILDER="${BUILDER:-sandbox-templates}"
# Appended to the immutable tag as `:<tag>-<shortsha><suffix>`. A scheduled
# rebuild runs against an unchanged commit, so it must pass a suffix (a date,
# a run id) or it would overwrite the immutable tag of the previous build.
IMMUTABLE_SUFFIX="${IMMUTABLE_SUFFIX:-}"
# Empty means "whatever the Dockerfile pins".
BASE_IMAGE="${BASE_IMAGE:-}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
PUSH=1
DRY_RUN=0
SMOKE_TEST=1

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options] [tag ...]

Builds and pushes the .NET sandbox template. With no tag arguments every
supported tag is built (currently: $(supported_tag_list)).

Options:
  --no-push                 Build for every platform but don't push.
  --platforms <list>        Comma-separated build platforms
                            (default: ${PLATFORMS}).
  --image <ref>             Target image without a tag
                            (default: ${IMAGE}).
  --immutable-suffix <s>    Extra suffix for the immutable tag, e.g. a date for
                            scheduled rebuilds of an unchanged commit.
  --base-image <ref>        Override the base image the Dockerfile pins.
  --allow-dirty             Permit pushing from a dirty working tree.
  --skip-smoke-test         Don't build and smoke-test a host-platform image
                            before publishing.
  --dry-run                 Print the buildx commands without running them.
  -h, --help                Show this help.

Every option also has an environment equivalent: IMAGE, PLATFORMS, SOURCE_URL,
BUILDER, IMMUTABLE_SUFFIX, BASE_IMAGE, ALLOW_DIRTY.

Pushing needs a registry login, e.g.
  echo "\$GITHUB_TOKEN" | docker login ghcr.io -u "\$GITHUB_ACTOR" --password-stdin
EOF
}

die() {
    printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*" >&2
}

supported_tag_list() {
    local entry tags=()
    for entry in "${SUPPORTED_TAGS[@]}"; do
        tags+=("${entry%%:*}")
    done
    printf '%s' "${tags[*]}"
}

channel_for_tag() {
    local wanted="$1" entry
    for entry in "${SUPPORTED_TAGS[@]}"; do
        if [ "${entry%%:*}" = "${wanted}" ]; then
            printf '%s' "${entry#*:}"
            return 0
        fi
    done
    return 1
}

parse_args() {
    REQUESTED_TAGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-push) PUSH=0 ;;
            --platforms) PLATFORMS="${2:?--platforms needs a value}"; shift ;;
            --image) IMAGE="${2:?--image needs a value}"; shift ;;
            --immutable-suffix) IMMUTABLE_SUFFIX="${2:?--immutable-suffix needs a value}"; shift ;;
            --base-image) BASE_IMAGE="${2:?--base-image needs a value}"; shift ;;
            --allow-dirty) ALLOW_DIRTY=1 ;;
            --skip-smoke-test) SMOKE_TEST=0 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "unknown option: $1 (try --help)" ;;
            *) REQUESTED_TAGS+=("$1") ;;
        esac
        shift
    done

    if [ ${#REQUESTED_TAGS[@]} -eq 0 ]; then
        local entry
        for entry in "${SUPPORTED_TAGS[@]}"; do
            REQUESTED_TAGS+=("${entry%%:*}")
        done
    fi

    local tag
    for tag in "${REQUESTED_TAGS[@]}"; do
        channel_for_tag "${tag}" >/dev/null \
            || die "unsupported tag: ${tag} (supported: $(supported_tag_list))"
    done
}

# The immutable tag claims to describe a commit, so refuse to mint one from a
# tree that doesn't match any commit.
resolve_revision() {
    git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git checkout: ${REPO_ROOT}"

    REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    SHORT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD)"

    if [ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]; then
        if [ "${PUSH}" = "1" ] && [ "${DRY_RUN}" != "1" ] && [ "${ALLOW_DIRTY}" != "1" ]; then
            die "working tree is dirty; commit first or pass --allow-dirty"
        fi
        printf '%s: warning: building from a dirty working tree\n' "${SCRIPT_NAME}" >&2
    fi
}

# Multi-platform builds need the docker-container driver; the default "docker"
# driver can only build for the host platform. Reuse the selected builder when
# it already qualifies (CI sets one up via docker/setup-buildx-action).
ensure_builder() {
    BUILDER_ARGS=()

    # Probing the selected builder is best-effort: if there isn't one, or it
    # can't be reached, we just fall through and use our own. Keep the probe
    # inside an `if` so a non-zero exit can't trip `set -e`, capture the output
    # in full rather than piping into an awk that exits early (a closed pipe
    # would SIGPIPE the writer), and keep stderr so a failure explains itself
    # instead of aborting the script with no diagnostic at all.
    local inspect_out="" current_driver=""
    if inspect_out="$(docker buildx inspect 2>&1)"; then
        current_driver="$(printf '%s\n' "${inspect_out}" | awk -F': *' '/^Driver:/ && !seen {print $2; seen = 1}')"
    else
        printf '%s: note: cannot inspect the current buildx builder, falling back to %s:\n%s\n' \
            "${SCRIPT_NAME}" "${BUILDER}" "${inspect_out}" >&2
    fi

    if [ -n "${current_driver}" ] && [ "${current_driver}" != "docker" ]; then
        log "Using the current buildx builder (driver: ${current_driver})"
        return 0
    fi

    if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
        log "Creating buildx builder '${BUILDER}' (driver: docker-container)"
        run docker buildx create --name "${BUILDER}" --driver docker-container --bootstrap >/dev/null
    fi
    BUILDER_ARGS=(--builder "${BUILDER}")
}

run() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf '+ %s\n' "$*" >&2
        return 0
    fi
    "$@"
}

# An image can build, push and verify its platforms while being functionally
# empty -- #9 shipped one whose cert bootstrap was wired to nothing. So run the
# image before publishing it. Only the host platform can be executed here (the
# other arch would need emulation), which is enough to catch a missing payload;
# the layers are shared with the multi-arch build that follows, so this mostly
# comes out of cache.
smoke_test_tag() {
    local tag="$1" channel local_ref
    channel="$(channel_for_tag "${tag}")"
    local_ref="${IMAGE}:${tag}-smoke"

    log "Smoke-testing ${IMAGE}:${tag} on the host platform"
    run docker buildx build ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
        --build-arg "DOTNET_CHANNEL=${channel}" \
        --build-arg "TEMPLATE_REVISION=${REVISION}" \
        --tag "${local_ref}" \
        --load \
        "${CONTEXT_DIR}"
    run "${REPO_ROOT}/scripts/smoke-test.sh" "${local_ref}" "${tag}"
}

build_tag() {
    local tag="$1"
    local channel immutable_tag
    channel="$(channel_for_tag "${tag}")"
    immutable_tag="${tag}-${SHORT_SHA}${IMMUTABLE_SUFFIX}"

    local args=(
        docker buildx build ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"}
        --platform "${PLATFORMS}"
        --build-arg "DOTNET_CHANNEL=${channel}"
        --build-arg "TEMPLATE_REVISION=${REVISION}"
        --tag "${IMAGE}:${tag}"
        --tag "${IMAGE}:${immutable_tag}"
        --label "org.opencontainers.image.source=${SOURCE_URL}"
        --label "org.opencontainers.image.revision=${REVISION}"
        --label "org.opencontainers.image.version=${immutable_tag}"
        --label "org.opencontainers.image.title=dotnet sandbox template"
        --label "org.opencontainers.image.description=Docker Sandbox template for C#/.NET ${channel} development with EF Core"
    )
    if [ -n "${BASE_IMAGE}" ]; then
        args+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
    fi

    if [ "${PUSH}" = "1" ]; then
        # Attestations are only meaningful once they reach a registry. Both
        # flags take an *optional* value, so they must use the `=` form.
        args+=(--provenance=mode=max --sbom=true --push)
    else
        args+=(--output "type=image,push=false")
    fi
    args+=("${CONTEXT_DIR}")

    log "Building ${IMAGE}:${tag} (and :${immutable_tag}) for ${PLATFORMS}"
    run "${args[@]}"
}

# A push that silently produced a single-platform image would defeat the point.
verify_platforms() {
    local tag="$1" ref="${IMAGE}:${tag}" platform manifest
    manifest="$(docker buildx imagetools inspect "${ref}" 2>&1)" \
        || die "cannot inspect ${ref} after push: ${manifest}"

    local IFS=','
    for platform in ${PLATFORMS}; do
        printf '%s\n' "${manifest}" | grep -Eq "^[[:space:]]*Platform:[[:space:]]+${platform}[[:space:]]*$" \
            || die "${ref} is missing platform ${platform}"
    done
    log "Verified ${ref} publishes ${PLATFORMS}"
}

main() {
    parse_args "$@"
    command -v docker >/dev/null || die "docker is not installed"
    docker buildx version >/dev/null 2>&1 || die "docker buildx is not available"

    resolve_revision
    ensure_builder

    local tag
    for tag in "${REQUESTED_TAGS[@]}"; do
        if [ "${SMOKE_TEST}" = "1" ]; then
            smoke_test_tag "${tag}"
        fi
        build_tag "${tag}"
    done

    if [ "${PUSH}" = "1" ] && [ "${DRY_RUN}" != "1" ]; then
        for tag in "${REQUESTED_TAGS[@]}"; do
            verify_platforms "${tag}"
        done
    fi

    log "Done: ${REQUESTED_TAGS[*]}"
}

main "$@"
