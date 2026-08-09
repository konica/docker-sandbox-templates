#!/usr/bin/env bash
# Idempotent per-sandbox ASP.NET Core HTTPS dev-cert generator.
# Run at sandbox start. Generates a fresh cert + random password on first
# run and writes the password to $BASH_ENV; a rerun against an
# already-generated cert is a no-op so it never invalidates a cert a
# running Kestrel process already loaded.
set -euo pipefail

CERT_PATH="${ASPNETCORE_Kestrel__Certificates__Default__Path:-${HOME}/.aspnet/https/dev-cert.pfx}"
ENV_FILE="${BASH_ENV:-/etc/sandbox-persistent.sh}"
PASSWORD_VAR="ASPNETCORE_Kestrel__Certificates__Default__Password"

if [ -f "${CERT_PATH}" ] && grep -q "^export ${PASSWORD_VAR}=" "${ENV_FILE}" 2>/dev/null; then
    exit 0
fi

mkdir -p "$(dirname "${CERT_PATH}")"
rm -f "${CERT_PATH}"

PASSWORD="$(openssl rand -base64 32)"

dotnet dev-certs https --clean >/dev/null 2>&1 || true
dotnet dev-certs https -ep "${CERT_PATH}" -p "${PASSWORD}" >/dev/null
chmod 600 "${CERT_PATH}"

TMP_FILE="$(mktemp)"
if [ -f "${ENV_FILE}" ]; then
    grep -v "^export ${PASSWORD_VAR}=" "${ENV_FILE}" > "${TMP_FILE}" 2>/dev/null || true
fi
printf 'export %s=%q\n' "${PASSWORD_VAR}" "${PASSWORD}" >> "${TMP_FILE}"
cat "${TMP_FILE}" > "${ENV_FILE}"
rm -f "${TMP_FILE}"
