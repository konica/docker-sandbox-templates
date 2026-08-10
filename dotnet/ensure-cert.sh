#!/usr/bin/env bash
# Idempotent per-sandbox ASP.NET Core HTTPS dev-cert generator.
#
# Invoked from the template's BASH_ENV hook on first use. A rerun once the cert
# exists is a no-op, so it never invalidates a cert a running Kestrel has
# already loaded.
#
# The password goes to its own file rather than into $BASH_ENV: the hook is
# sourced before every command, and rewriting a file while it is being read is
# a good way to produce a truncated environment.
set -euo pipefail

CERT_PATH="${ASPNETCORE_Kestrel__Certificates__Default__Path:-${HOME}/.aspnet/https/dev-cert.pfx}"
CERT_DIR="$(dirname "${CERT_PATH}")"
ENV_FILE="${DOTNET_DEV_CERT_ENV_FILE:-${CERT_DIR}/dev-cert.env}"
PASSWORD_VAR="ASPNETCORE_Kestrel__Certificates__Default__Password"

is_ready() {
    [ -f "${CERT_PATH}" ] && [ -s "${ENV_FILE}" ]
}

is_ready && exit 0

mkdir -p "${CERT_DIR}"

# Any bash command in the sandbox can trigger this, so two can arrive at once.
# Serialise on a lock beside the cert and re-check inside it, or one shell would
# hand Kestrel a cert whose password another shell has already replaced.
exec 9>"${CERT_DIR}/.ensure-cert.lock"
if command -v flock >/dev/null; then
    flock 9
fi

is_ready && exit 0

PASSWORD="$(openssl rand -base64 32)"

dotnet dev-certs https --clean >/dev/null 2>&1 || true

# Build both files under temporary names and move them into place, so a
# concurrent reader never sees a half-written cert or a password that does not
# match the cert next to it.
tmp_cert="${CERT_PATH}.tmp.$$"
tmp_env="${ENV_FILE}.tmp.$$"
trap 'rm -f "${tmp_cert}" "${tmp_env}"' EXIT

dotnet dev-certs https -ep "${tmp_cert}" -p "${PASSWORD}" >/dev/null
chmod 600 "${tmp_cert}"

printf 'export %s=%q\n' "${PASSWORD_VAR}" "${PASSWORD}" > "${tmp_env}"
chmod 600 "${tmp_env}"

mv -f "${tmp_cert}" "${CERT_PATH}"
mv -f "${tmp_env}" "${ENV_FILE}"
