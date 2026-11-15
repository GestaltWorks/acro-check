# acro-check

Sends Acronis Cyber Protect Cloud alerts to a Teams, Slack or Discord channel, and posts again when they clear.

Acronis has no outgoing webhooks, and Workflow Automation has no "call a URL" action. Without this, alerts leave the console only by email or through a supported PSA. acro-check polls the Alert Manager API every 15 seconds and turns each new alert into a channel card.

One PowerShell script plus a helper file. It runs three ways:

- in Windows PowerShell 5.1 or PowerShell 7 on a PC, with no install and no admin rights
- in Docker on any server: [Run it on a server](#run-it-on-a-server-docker)
- as a plain `.ps1` on a Windows Server without Docker

## What it does

| Feature | What you see |
|---|---|
| New alert | A card with the device, plan, root cause, severity and time, colored by severity |
| Alert clears | A green "Acronis alert cleared" card saying who cleared it and how long it was open |
| Clear alert button | A button on the card that dismisses that one alert in Acronis |
| Repeat alert | The card says "repeat (N times)", with "times seen" and "first reported" |
| Removed device | Alerts on a device that no longer exists in Acronis are cleared automatically |
| Severity filter | Only error and critical alerts post by default; warnings stay out of the channel. Malware detections always post: Acronis rates a quarantined one "warning", so the bridge treats security detections as critical |
| Quiet window | One status line, rewritten in place: green Ready, yellow for warnings, red for error or critical |

## Set up (about 10 minutes, once)

1. Create an API client in the Cyber Console: **Settings > General settings > API clients**. Keep the Client ID and the Secret, which is shown only once.
2. Create the channel's incoming webhook:
   - **Teams:** in the channel, choose **Workflows > Post to a channel when a webhook request is received**, then copy the URL.
   - **Slack** or **Discord:** create an incoming webhook for the channel.
3. Make your settings file in your user profile, where every copy of acro-check finds it (a fresh clone included). Open PowerShell in this folder:

   ```powershell
   New-Item -ItemType Directory -Force "$HOME\.acro-check" | Out-Null; Copy-Item .\acro-check.env.example.ps1 "$HOME\.acro-check\acro-check.env.ps1"
   ```

   ```powershell
   notepad "$HOME\.acro-check\acro-check.env.ps1"
   ```

   Fill in the four values:
   - the data center URL (the start of the console's address, up to `.com`)
   - the Client ID
   - the Secret
   - the webhook URL

   The scripts look for `acro-check.env.ps1` next to themselves first, then in `%USERPROFILE%\.acro-check\`. Values already set in the window win over both. Git ignores `acro-check.env.ps1` in this folder, so the values never reach the repo.
4. Check it without posting anything:

   ```powershell
   .\acronis-alert-bridge.ps1 -Target teams -Once -DryRun
   ```

   It prints `Connected: <your tenant>` and a status line. A `401` means the Client ID, Secret or URL is wrong.

If scripts are blocked on this PC, run this first. It applies to this window only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## Run it

```powershell
.\acronis-alert-bridge.ps1 -Target teams
```

Ctrl+C stops it. On its first start it marks the alerts that already exist as seen and posts only new ones (`-Backfill` posts the existing ones too).

On a PC the Clear alert button opens `localhost`, so it works only on the PC running the bridge, and only while it runs. On a server it gets a public address: see below.

## Run it on a server (Docker)

The image is the official PowerShell image with the two scripts. You build it straight from this repo, so there's no registry and nothing to clone.

1. On the server, put the settings in `~/.acro-check/.env` (format in [.env.example](.env.example)), then:

   ```bash
   chmod 600 ~/.acro-check/.env
   ```

2. Build and start it:

   ```bash
   docker build -t acro-check https://github.com/GestaltWorks/acro-check.git
   ```

   ```bash
   docker run -d --name acro-check --restart unless-stopped --env-file ~/.acro-check/.env -p 127.0.0.1:8765:8765 -v acro-check-data:/data acro-check
   ```

3. Watch it:

   ```bash
   docker logs -f acro-check
   ```

The Clear alert button needs a public HTTPS address. Point a reverse proxy at `127.0.0.1:8765`, and set `ACRO_CLEAR_URL` in the `.env` to the matching public URL. For nginx, inside the site's `server { }` block:

```nginx
location /acro-check/ {
    proxy_pass http://127.0.0.1:8765/;
}
```

The bridge only answers `/clear` links that carry its random key, for alerts it posted that are still open. Everything else gets a 404.

State (posted alerts, repeat counts, the Clear key) lives on the `acro-check-data` volume, so restarts and rebuilds don't repost. To start over:

```bash
docker rm -f acro-check && docker volume rm acro-check-data
```

Container settings, all in the `.env`:

| Variable | What it is |
|---|---|
| `ACRONIS_BASE_URL`, `ACRONIS_CLIENT_ID`, `ACRONIS_CLIENT_SECRET` | The API client |
| `ACRONIS_ALERT_WEBHOOK` | The channel's webhook |
| `ACRO_CLEAR_URL` | Public URL of the Clear button, ending in `/clear` |
| `TZ` | Time zone for card times, for example `America/New_York` (UTC if unset) |

The image already sets `ACRO_LISTEN=http://*:8765/` and `ACRO_STATE=/data/acronis-alert-bridge.state.json`. To pass options, put them after the image name, for example `... acro-check -Target slack -MinSeverity warning`.

### Parameters

| Parameter | Default | What it does |
|---|---|---|
| `-Target` | `teams` | Message format: `teams`, `slack` or `discord` |
| `-MinSeverity` | `error` | Lowest severity posted: `information`, `warning`, `error`, `critical` |
| `-IntervalSeconds` | `15` | Seconds between checks |
| `-WebhookUrl` | `$env:ACRONIS_ALERT_WEBHOOK` | Overrides the webhook from the settings file |
| `-State` | `$env:ACRO_STATE`, else `acronis-alert-bridge.state.json` next to the script | Where it remembers what it posted |
| `-ClearPort` | `8765` | Local port for the Clear alert button |
| `-ClearUrl` | `$env:ACRO_CLEAR_URL`, else `http://localhost:8765/clear` | The address the card's button opens |
| `-Listen` | `$env:ACRO_LISTEN`, else `http://localhost:8765/` | What the listener binds (`http://*:8765/` in the container) |
| `-NoClearButton` | off | Posts cards without the Clear alert button |
| `-Once` | off | Checks one time and exits |
| `-DryRun` | off | Prints cards instead of posting them, and dismisses nothing |
| `-Backfill` | off | On first start, also posts alerts that already exist |
| `-Raw` | off | Prints each API response (cut to 1500 characters) for debugging |

### Examples

See what it would post right now, without posting:

```powershell
.\acronis-alert-bridge.ps1 -Target teams -Once -DryRun -Backfill
```

Let warnings through too:

```powershell
.\acronis-alert-bridge.ps1 -Target teams -MinSeverity warning
```

Post to Slack instead:

```powershell
.\acronis-alert-bridge.ps1 -Target slack
```

## The window

The window keeps one status line, rewritten every round:

```
Status: Ready. No open alerts. Checked 9:07:14 PM                ← green
Status: Ready. 1 warning open, not sent. Checked 9:08:02 PM      ← yellow
Status: 2 open (critical). Nothing new. Checked 9:08:21 PM       ← red
```

Events print on their own line above it:

```
8:41:19 PM  posted: [critical] Backup Failed on Hudson
8:42:04 PM  Clear alert clicked: dismissed 97DDE87E-... in Acronis
8:42:06 PM  cleared: Backup Failed on Hudson  (by the Clear alert button in teams, through the API)
10:05:20 PM  auto-cleared: Backup Failed on ubuntu  (device ubuntu was removed)
```

## The cards

A new alert:

```
🔴 Acronis alert, repeat (3 times)
Backup Failed on Hudson
resourceName   Hudson
planName       New protection plan
error          DNS hostname resolution error (storage upgd24gtd.tempe:44445)
error code     MemoDnsError
severity       critical
category       Backup
raised         11/14/2026 4:38 PM
times seen     3
first reported 11/14/2026 2:06 PM
tenant         David Braun
[Clear alert]  [Open the console]
```

When it clears:

```
✅ Acronis alert cleared
Backup Failed on Hudson
cleared        11/14/2026 8:42 PM
cleared by     the Clear alert button in teams, through the API
open for       43 min 5 s
tenant         David Braun
```

"cleared by" is one of:
- the Clear alert button
- the bridge itself, when the device was removed
- Acronis, when it was cleared in the console or cleared by itself

## What it writes, and where

| What | Where | Committed |
|---|---|---|
| Credentials and webhook (PC) | `%USERPROFILE%\.acro-check\acro-check.env.ps1` | No (outside the repo) |
| Credentials and webhook (server) | `~/.acro-check/.env` | No (outside the repo) |
| Posted alerts, repeat counts, Clear button key | `acronis-alert-bridge.state.json`, or the `acro-check-data` volume | No (git ignores it) |
| Dismiss one alert | Acronis, `DELETE /api/alert_manager/v1/alerts/{id}` | n/a |

The bridge reads Acronis and posts to the channel. It changes Acronis only in two cases:
- someone clicks Clear alert
- an alert belongs to a device that was removed

In both cases it dismisses that one alert and nothing else.

## Files

| File | What it is |
|---|---|
| `acronis-alert-bridge.ps1` | The bridge |
| `acronis-common.ps1` | Shared helpers: sign in, GET with readable errors, list unwrapping |
| `acro-check.env.example.ps1` | Template for the PC settings file |
| `Dockerfile`, `.env.example` | The container, and the template for its settings |
| [docs/how-it-works.md](docs/how-it-works.md) | The poll loop, state, repeat counting, Clear button, removed devices, root cause |
| [docs/acronis-api-notes.md](docs/acronis-api-notes.md) | Acronis API behavior learned building this, with the gotchas |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms, causes and fixes |

## Limits

- On a PC the Clear alert button opens `localhost`, so it works only there. Run it on a server with `ACRO_CLEAR_URL` for a button that works for everyone in the channel.
- Anyone who has a card can use its Clear button. That's the point in a team channel, but the key travels inside the card.
- Repeat counts start when the bridge first sees an alert. Acronis keeps no count, so repeats from before that aren't counted.
- Polling every 15 seconds means a card arrives up to 15 seconds after the alert.
- Teams Workflows webhooks can't edit a card after posting it, so clearing posts a second card instead of updating the first.
- The device check catches devices removed from Acronis. A device that is offline but still listed keeps its alerts, which is correct.
