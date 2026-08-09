#!/usr/bin/env bash
# Idempotent per-sandbox ASP.NET Core HTTPS dev-cert bootstrap.
# Safe to run on every sandbox start: generates a fresh cert + random
# password on first run, then reuses both on later runs. No secret is
# baked into the image -- everything here is created inside the running
# container and the password only ever lives in $BASH_ENV.
set -euo pipefail

CERT_DIR="${HOME}/.aspnet/https"
CERT_PATH="${CERT_DIR}/dev-cert.pfx"
CERT_PASSWORD_FILE="${CERT_DIR}/.dev-cert-password"
ENV_FILE="${BASH_ENV:-/etc/sandbox-persistent.sh}"
ENV_VAR="ASPNETCORE_Kestrel__Certificates__Default__Password"

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ ! -s "$CERT_PATH" ] || [ ! -s "$CERT_PASSWORD_FILE" ]; then
    rm -f "$CERT_PATH" "$CERT_PASSWORD_FILE"
    PASSWORD="$(openssl rand -base64 32)"
    dotnet dev-certs https -ep "$CERT_PATH" -p "$PASSWORD" >/dev/null
    (umask 077 && printf '%s' "$PASSWORD" >"$CERT_PASSWORD_FILE")
else
    PASSWORD="$(cat "$CERT_PASSWORD_FILE")"
fi

# Rewrite by truncating the existing file in place rather than sed -i,
# which creates a temp file in the same directory: /etc is root-owned, so
# only the file itself (agent-owned) is writable, not the directory.
REST="$(grep -v "^export ${ENV_VAR}=" "$ENV_FILE" 2>/dev/null || true)"
{
    [ -n "$REST" ] && printf '%s\n' "$REST"
    printf "export %s='%s'\n" "$ENV_VAR" "$PASSWORD"
} >"$ENV_FILE"
