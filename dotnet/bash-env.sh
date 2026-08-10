# Sourced before every bash command via BASH_ENV / CLAUDE_ENV_FILE.
#
# This is the template's startup hook. A custom ENTRYPOINT was tried first and
# broke sandbox creation outright ("failed to run sandbox container"), so the
# image's startup contract is left exactly as the base image defines it and the
# cert bootstrap hangs off the environment file instead.
#
# Two rules for anything added here, because it runs ahead of *every* command:
# it must stay silent (output would corrupt the output of every command), and
# it must end with a zero status (a non-zero tail can abort callers running
# under `set -e`).

# The sandbox manager owns /etc/sandbox-persistent.sh -- it writes a managed
# block into it at sandbox creation -- so chain to it rather than appending to
# it and risking the edit being overwritten.
if [ -f /etc/sandbox-persistent.sh ]; then
    . /etc/sandbox-persistent.sh
fi

# Generate the per-sandbox HTTPS dev cert on first use.
#
# DOTNET_DEV_CERT_BOOTSTRAP breaks a recursion that would otherwise be fatal:
# ensure-cert.sh is itself a bash script, so running it starts a bash that
# sources this file again. The marker bounds the cost when generation cannot
# succeed at all, so a broken cert costs one attempt per container rather than
# one per command.
if [ -z "${DOTNET_DEV_CERT_BOOTSTRAP:-}" ] \
    && [ -n "${ASPNETCORE_Kestrel__Certificates__Default__Path:-}" ] \
    && [ ! -f "${ASPNETCORE_Kestrel__Certificates__Default__Path}" ] \
    && [ ! -f /tmp/.dotnet-dev-cert-attempted ]; then
    : > /tmp/.dotnet-dev-cert-attempted 2>/dev/null || true
    DOTNET_DEV_CERT_BOOTSTRAP=1 /usr/local/bin/ensure-cert.sh >/dev/null 2>&1 || true
fi

# Publishes ASPNETCORE_Kestrel__Certificates__Default__Password. Kept out of
# /etc/sandbox-persistent.sh so nothing rewrites a file while it is being
# sourced, and mode 600 rather than that file's world-readable 644.
if [ -f "${DOTNET_DEV_CERT_ENV_FILE:-/home/agent/.aspnet/https/dev-cert.env}" ]; then
    . "${DOTNET_DEV_CERT_ENV_FILE:-/home/agent/.aspnet/https/dev-cert.env}"
fi
