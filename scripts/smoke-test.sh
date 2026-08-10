#!/usr/bin/env bash
# Assert that a built template image actually carries its payload and boots
# into a usable state.
#
# This exists because an image can build, push and verify its platforms while
# being functionally empty: the SDK layer can be missing, or -- as in #9 -- the
# dev-cert bootstrap can be present on disk but wired to nothing, so Kestrel is
# pointed at a certificate that is never generated.
#
# Every check runs the image through its real entrypoint, so it exercises the
# same startup path a sandbox gets.
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <image-ref> [expected-major-version]

Runs the image and asserts:
  - dotnet is on PATH and reports a version (matching the expected major
    version, when one is given)
  - dotnet-ef is installed and runnable
  - the ASP.NET HTTPS dev cert named by
    ASPNETCORE_Kestrel__Certificates__Default__Path exists after startup, and
    its password has been published to the environment file
EOF
}

die() {
    printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2
    exit 1
}

if [ $# -lt 1 ] || [ "${1}" = "-h" ] || [ "${1}" = "--help" ]; then
    usage
    [ $# -lt 1 ] && exit 1
    exit 0
fi

readonly IMAGE="$1"
readonly EXPECTED_MAJOR="${2:-}"

command -v docker >/dev/null || die "docker is not installed"

printf '==> Smoke-testing %s\n' "${IMAGE}" >&2

# One container, all assertions: starting the image is the expensive part, and
# the cert check is only meaningful after the entrypoint has run.
output="$(docker run --rm "${IMAGE}" bash -c '
set -uo pipefail
fail=0
note() { printf "%s\n" "$*"; }

if ! command -v dotnet >/dev/null; then
    note "FAIL dotnet: not on PATH"
    fail=1
else
    if version="$(dotnet --version 2>&1)"; then
        note "OK   dotnet ${version}"
    else
        note "FAIL dotnet --version: ${version}"
        fail=1
    fi
fi

if ef_version="$(dotnet ef --version 2>&1)"; then
    note "OK   dotnet-ef $(printf "%s" "${ef_version}" | tail -n 1)"
else
    note "FAIL dotnet ef --version: ${ef_version}"
    fail=1
fi

cert="${ASPNETCORE_Kestrel__Certificates__Default__Path:-}"
if [ -z "${cert}" ]; then
    note "FAIL cert: ASPNETCORE_Kestrel__Certificates__Default__Path is unset"
    fail=1
elif [ -f "${cert}" ]; then
    note "OK   cert ${cert}"
else
    note "FAIL cert: ${cert} does not exist after startup"
    fail=1
fi

env_file="${BASH_ENV:-/etc/sandbox-persistent.sh}"
if grep -q "^export ASPNETCORE_Kestrel__Certificates__Default__Password=" "${env_file}" 2>/dev/null; then
    note "OK   cert password published to ${env_file}"
else
    note "FAIL cert password missing from ${env_file}"
    fail=1
fi

exit "${fail}"
' 2>&1)" && status=0 || status=$?

printf '%s\n' "${output}"

# A template must still boot when the cert bootstrap cannot run. An entrypoint
# that exited non-zero here made sandboxes uncreatable ("failed to run sandbox
# container") while every check above still passed, so assert it explicitly:
# running as a uid that owns nothing makes the bootstrap fail, and the container
# must start regardless.
if docker run --rm --user 1001:1001 "${IMAGE}" true >/dev/null 2>&1; then
    printf 'OK   starts even when the cert bootstrap fails\n'
else
    printf 'FAIL image refuses to start when the cert bootstrap fails\n'
    status=1
fi

if [ -n "${EXPECTED_MAJOR}" ]; then
    printf '%s\n' "${output}" | grep -Eq "^OK   dotnet ${EXPECTED_MAJOR}\." \
        || die "expected a .NET ${EXPECTED_MAJOR}.x SDK"
fi

[ "${status}" -eq 0 ] || die "smoke test failed for ${IMAGE}"

printf '==> %s passed\n' "${IMAGE}" >&2
