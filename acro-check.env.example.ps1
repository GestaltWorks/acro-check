# Copy this file to acro-check.env.ps1 (git ignores that name) and fill in the four values.
# The bridge loads acro-check.env.ps1 by itself when the window has no ACRONIS_* variables set.

# Data center URL: the start of the console's address, up to .com
$env:ACRONIS_BASE_URL      = ""
# API client: Cyber Console > Settings > General settings > API clients
$env:ACRONIS_CLIENT_ID     = ""
$env:ACRONIS_CLIENT_SECRET = ""
# The channel's incoming webhook (Teams Workflows, Slack or Discord)
$env:ACRONIS_ALERT_WEBHOOK = ""
