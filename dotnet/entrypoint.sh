#!/usr/bin/env bash
# Bootstrap the per-sandbox HTTPS dev cert, then hand off to the base image's
# init.
#
# ensure-cert.sh shipped in the image from the very first build but nothing ever
# invoked it (#9): it was copied in, made executable, and then left alone. That
# left ASPNETCORE_Kestrel__Certificates__Default__Path naming a certificate
# which never existed, so every HTTPS app died on boot. Running it from the
# entrypoint covers every container start, whatever command the sandbox
# ultimately launches.
set -euo pipefail

if ! /usr/local/bin/ensure-cert.sh; then
    printf 'entrypoint: ensure-cert.sh failed; refusing to start with %s pointing at a certificate that does not exist\n' \
        "ASPNETCORE_Kestrel__Certificates__Default__Path=${ASPNETCORE_Kestrel__Certificates__Default__Path:-<unset>}" >&2
    exit 1
fi

# tini is the base image's entrypoint; keep reaping PID 1's children as before.
exec /usr/bin/tini -- "$@"
