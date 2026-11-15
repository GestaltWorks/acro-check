# Copy this file to %USERPROFILE%\.acro-check\acro-check.env.ps1 and fill in the four values.
# The scripts load it by themselves when the window has no ACRONIS_* variables set. They look
# next to the scripts first (git ignores acro-check.env.ps1 there), then in %USERPROFILE%\.acro-check\.

# Data center URL: the start of the console's address, up to .com
$env:ACRONIS_BASE_URL      = ""
# API client: Cyber Console > Settings > General settings > API clients
$env:ACRONIS_CLIENT_ID     = ""
$env:ACRONIS_CLIENT_SECRET = ""
# The channel's incoming webhook (Teams Workflows, Slack or Discord)
$env:ACRONIS_ALERT_WEBHOOK = ""
