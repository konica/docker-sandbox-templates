# .NET / C# / EF Docker Sandbox template.
# Build one tag per supported LTS channel:
#   docker build --build-arg DOTNET_CHANNEL=10.0 -t ghcr.io/konica/docker-sandbox-templates/dotnet:10 dotnet
#   docker build --build-arg DOTNET_CHANNEL=8.0  -t ghcr.io/konica/docker-sandbox-templates/dotnet:8  dotnet
FROM docker/sandbox-templates:claude-code

ARG DOTNET_CHANNEL=10.0

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet \
    && rm /tmp/dotnet-install.sh \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet

COPY --chown=agent:agent ensure-cert.sh /usr/local/bin/ensure-cert.sh
RUN chmod +x /usr/local/bin/ensure-cert.sh

ENV DOTNET_ROOT=/usr/share/dotnet \
    PATH="/home/agent/.dotnet/tools:${PATH}" \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    ASPNETCORE_HTTP_PORTS=8080 \
    ASPNETCORE_HTTPS_PORTS=8081 \
    ASPNETCORE_Kestrel__Certificates__Default__Path=/home/agent/.aspnet/https/dev-cert.pfx \
    BASH_ENV=/etc/sandbox-persistent.sh

USER agent

RUN dotnet tool install --global dotnet-ef \
    && dotnet nuget locals all --clear
