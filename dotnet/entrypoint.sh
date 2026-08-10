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

# Warn but carry on. An earlier version exited non-zero here, which turned any
# cert hiccup into "failed to run sandbox container" -- a dev certificate is not
# worth refusing to boot over, and a sandbox nobody can start is worse than one
# without HTTPS. The guarantee that the cert really is generated belongs in CI,
# where scripts/smoke-test.sh fails the build if it isn't.
if ! /usr/local/bin/ensure-cert.sh; then
    printf 'entrypoint: WARNING: ensure-cert.sh failed; ASP.NET HTTPS will not work until a certificate exists at %s. Starting anyway.\n' \
        "${ASPNETCORE_Kestrel__Certificates__Default__Path:-<unset>}" >&2
fi

# tini is the base image's entrypoint; keep reaping PID 1's children as before.
exec /usr/bin/tini -- "$@"
