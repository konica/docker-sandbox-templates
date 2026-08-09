# syntax=docker/dockerfile:1

# Pinned by digest so a rebuild can't silently pick up a different base. This is
# the multi-arch index digest, so it still resolves per target platform. Refresh
# it deliberately with:
#   docker buildx imagetools inspect docker/sandbox-templates:claude-code \
#     --format '{{.Manifest.Digest}}'
ARG BASE_IMAGE=docker/sandbox-templates:claude-code@sha256:7fa049b8d7a0cf10f6a4200148ee475e94fc4fb5ef50dfacc4257699cb9a34bc
FROM ${BASE_IMAGE}

ARG DOTNET_CHANNEL=10.0

ENV DOTNET_ROOT=/usr/share/dotnet \
    PATH="/usr/share/dotnet:/home/agent/.dotnet/tools:${PATH}" \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    ASPNETCORE_HTTP_PORTS=8080 \
    ASPNETCORE_HTTPS_PORTS=8081 \
    ASPNETCORE_Kestrel__Certificates__Default__Path=/home/agent/.aspnet/https/dev-cert.pfx \
    BASH_ENV=/etc/sandbox-persistent.sh

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends libicu-dev tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir "${DOTNET_ROOT}" \
    && rm /tmp/dotnet-install.sh \
    && ln -sf "${DOTNET_ROOT}/dotnet" /usr/bin/dotnet

COPY --chown=agent:agent ensure-cert.sh /home/agent/.local/bin/ensure-cert.sh
RUN chmod +x /home/agent/.local/bin/ensure-cert.sh

USER agent
WORKDIR /home/agent

RUN dotnet tool install --global dotnet-ef
