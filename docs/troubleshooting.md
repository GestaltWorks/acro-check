# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Set the ACRONIS_BASE_URL environment variable first.` | No `acro-check.env.ps1`, or it's empty | Do step 3 of the setup in the README |
| `401` on start | Wrong Client ID, Secret or data center URL | Fix them in `acro-check.env.ps1`. The URL is the console's address up to `.com` |
| `Set -WebhookUrl or the ACRONIS_ALERT_WEBHOOK environment variable` | No webhook in the settings file | Add it, or run with `-DryRun` |
| `post failed: ... 400` from Teams | The Workflow isn't "Post to a channel when a webhook request is received", or the URL was cut off | Copy the whole URL again from the Workflow |
| `Clear alert button off: port 8765 is in use` | Another bridge window is running | Close the other window, or use `-ClearPort 8766` |
| Clear button opens a page that won't load | The bridge isn't running. On a PC, or it runs on a different PC | Start it. On a PC the button only works there: run it on a server with `ACRO_CLEAR_URL` |
| Clear button gives `502 Bad Gateway` | The reverse proxy can't reach the container | `docker ps` shows `acro-check` up with `127.0.0.1:8765->8765/tcp`. If not, `docker start acro-check` |
| Card times are 5 hours off | The container has no `TZ` | Add `TZ=<your zone>` to the `.env`, then `docker rm -f acro-check` and run it again |
| Every alert posts twice | Two bridges run against the same channel (a PC window and the container) | Stop one |
| "This link isn't one the alert bridge made." | The state file was deleted, so the key changed, and the card is older than that | Clear the alert in the console. New cards get working buttons |
| Cards made before a restart have no Clear button | Those cards were posted by an older version | Nothing to fix. Posted cards can't be edited |
| A repeat wasn't posted | Its severity is below `-MinSeverity` (default `error`) | `-MinSeverity warning` to include warnings |
| The status line counts an alert that is gone from the console | The device was removed. The bridge clears it on its next round | Wait one round (15 s). If it stays, check the window for `auto-clear failed` |
| The status line jumps to a new line | The window is narrower than the line was when it was written | Widen the window; the next round writes a clean line |
| `GET ... skipped: HTTP 5xx` | Acronis hiccup | Nothing. The round is skipped and the next one retries |
| Backup alert says `DNS hostname resolution error (storage ...)` | The agent can't resolve the storage host Acronis gave it | Run `nslookup <host>` on the device. If public DNS can't resolve it either, the problem is on Acronis's side |
