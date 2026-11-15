# acro-check

Sends Acronis Cyber Protect Cloud alerts to a Teams, Slack or Discord channel, and posts again when they clear.

Acronis has no outgoing webhooks, and Workflow Automation has no "call a URL" action. Without this, alerts leave the console only by email or through a supported PSA. acro-check polls the Alert Manager API every 15 seconds and turns each new alert into a channel card.

One PowerShell script plus a helper file. It needs no install and no admin rights, and runs in Windows PowerShell 5.1 or PowerShell 7.

## What it does

| Feature | What you see |
|---|---|
| New alert | A card with the device, plan, root cause, severity and time, colored by severity |
| Alert clears | A green "Acronis alert cleared" card saying who cleared it and how long it was open |
| Clear alert button | A button on the card that dismisses that one alert in Acronis |
| Repeat alert | The card says "repeat (N times)", with "times seen" and "first reported" |
| Removed device | Alerts on a device that no longer exists in Acronis are cleared automatically |
| Severity filter | Only error and critical alerts post by default; warnings stay out of the channel |
| Quiet window | One status line, rewritten in place: green Ready, yellow for warnings, red for error or critical |

## Set up (about 10 minutes, once)

1. Create an API client in the Cyber Console: **Settings > General settings > API clients**. Keep the Client ID and the Secret, which is shown only once.
2. Create the channel's incoming webhook:
   - **Teams:** in the channel, choose **Workflows > Post to a channel when a webhook request is received**, then copy the URL.
   - **Slack** or **Discord:** create an incoming webhook for the channel.
3. Open PowerShell in this folder and make your settings file:

   ```powershell
   Copy-Item .\acro-check.env.example.ps1 .\acro-check.env.ps1
   ```

   ```powershell
   notepad .\acro-check.env.ps1
   ```

   Fill in the four values:
   - the data center URL (the start of the console's address, up to `.com`)
   - the Client ID
   - the Secret
   - the webhook URL

   Git ignores `acro-check.env.ps1`, so the values never reach the repo.
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

The Clear alert button only works while the bridge runs, and only on the PC running it.

### Parameters

| Parameter | Default | What it does |
|---|---|---|
| `-Target` | `teams` | Message format: `teams`, `slack` or `discord` |
| `-MinSeverity` | `error` | Lowest severity posted: `information`, `warning`, `error`, `critical` |
| `-IntervalSeconds` | `15` | Seconds between checks |
| `-WebhookUrl` | `$env:ACRONIS_ALERT_WEBHOOK` | Overrides the webhook from the settings file |
| `-State` | `acronis-alert-bridge.state.json` next to the script | Where it remembers what it posted |
| `-ClearPort` | `8765` | Local port for the Clear alert button |
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
| Credentials and webhook | `acro-check.env.ps1` | No (git ignores it) |
| Posted alerts, repeat counts, Clear button key | `acronis-alert-bridge.state.json` | No (git ignores it) |
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
| `acro-check.env.example.ps1` | Template for your settings file |
| [docs/how-it-works.md](docs/how-it-works.md) | The poll loop, state, repeat counting, Clear button, removed devices, root cause |
| [docs/acronis-api-notes.md](docs/acronis-api-notes.md) | Acronis API behavior learned building this, with the gotchas |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms, causes and fixes |

## Limits

- The Clear alert button opens `localhost`, so it works only on the PC running the bridge. A team would host it behind a reachable URL, or use a Teams bot instead of a Workflows webhook.
- Repeat counts start when the bridge first sees an alert. Acronis keeps no count, so repeats from before that aren't counted.
- Polling every 15 seconds means a card arrives up to 15 seconds after the alert.
- Teams Workflows webhooks can't edit a card after posting it, so clearing posts a second card instead of updating the first.
- The device check catches devices removed from Acronis. A device that is offline but still listed keeps its alerts, which is correct.
