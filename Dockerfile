# acro-check in a container: the same PowerShell script, on the official PowerShell image.
#
#   docker build -t acro-check https://github.com/GestaltWorks/acro-check.git
#   docker run -d --name acro-check --restart unless-stopped --env-file ~/.acro-check/.env \
#     -p 127.0.0.1:8765:8765 -v acro-check-data:/data acro-check
#   docker logs -f acro-check
#
# Settings come from the env file (see .env.example). Put a reverse proxy in front of port 8765
# and set ACRO_CLEAR_URL to its public address so the card's Clear alert button can reach it.
FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

# Time zone data, so card times follow TZ from the env file instead of UTC.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY acronis-common.ps1 acronis-alert-bridge.ps1 ./

# Listen on all interfaces inside the container; keep state on a volume so restarts don't repost.
ENV ACRO_LISTEN=http://*:8765/ \
    ACRO_STATE=/data/acronis-alert-bridge.state.json
VOLUME /data
EXPOSE 8765

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/acronis-alert-bridge.ps1"]
CMD ["-Target", "teams"]
