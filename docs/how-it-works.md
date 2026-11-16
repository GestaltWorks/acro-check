# How acro-check works

## The loop

```
start
  ├─ sign in (client credentials, then a tenant-scoped token)
  ├─ load state: posted occurrences, repeat counts, Clear button key
  ├─ watch alerts posted before this start that are still open
  ├─ start the Clear button listener on localhost:8765
  └─ every 15 s:
       1. GET open alerts
       2. drop alerts whose device was removed (and dismiss them)
       3. post new occurrences at or above -MinSeverity, plus malware and $alwaysPost types
       4. post "cleared" for posted alerts that are no longer open
       5. save state, rewrite the status line
     between rounds: answer Clear button clicks
```

The token is renewed after 100 minutes; Acronis tokens last 2 hours.

If the alert list call fails, the round is skipped. A failed call returns nothing, and treating "nothing" as "every alert cleared" would post a cleared card for every open alert.

## Signing in

`Connect-Acronis` in `acronis-common.ps1`:

1. `POST /api/2/idp/token` with `grant_type=client_credentials` and Basic auth (Client ID and Secret).
2. `GET /api/2/clients/{client_id}` gives the API client's `tenant_id`.
3. `POST /api/2/idp/token` again with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`, the first token as `assertion`, and `scope=urn:acronis.com:tenant-id:{tenant_id}`.

The protection services (alerts, resources, plans) return full data only with the scoped token from step 3.

## What counts as new

Acronis reuses an alert's ID when the same problem comes back: it reopens the alert with a new `createdAt`. Keying on the ID alone would skip every repeat.

So the bridge keys each **occurrence** as `ID|createdAt`, with the time cut to the second in UTC (`yyyy-MM-ddTHH:mm:ss`). PowerShell 7 parses dates in JSON into DateTime objects, while 5.1 leaves them as strings. `Get-Key` normalizes both, so a state file written by one version works in the other.

An alert is new when its occurrence key isn't in `posted` and `Test-Send` passes: its severity (after `Get-Sev` promotes malware detections to critical) is at or above `-MinSeverity`, or its type is in `$alwaysPost`. That list holds the warnings that mean a missed or weakened protection: `BackupDidNotStart`, `BackupStatusUnknown` and `MiMonitoringAntimalwareDefinitionsOutdated`. They post at their own severity, as yellow cards.

## Repeat counting

Acronis keeps no repeat count, so the bridge keeps one:

- `counts[ID]` goes up by one for each new occurrence of that ID.
- `countedKeys` stops one occurrence being counted twice. A post that fails is retried on the next round, but it is the same occurrence.
- State files from before the counter existed hold bare IDs. Each one loads as "seen once".

When the count is above 1, the card says "repeat (N times)" and adds:
- **times seen:** the count
- **first reported:** the alert's `receivedAt`. Acronis keeps that from the first report even when it reopens the alert.

The point: don't open a new ticket for every repeat, but do notice that it is the 14th time and go find the cause.

## Clearing

The bridge keeps `open`, a list of alerts it posted that are still active. Each round:

1. Any ID in `open` that is missing from the active list might have cleared.
2. The bridge confirms by reading the dismissed list (`show_deleted_only=true`). An alert missing from both lists might be a paging gap, so it is not posted as cleared.
3. For each confirmed one, it posts the cleared card with `deletedAt`, who cleared it, and how long it was open.

"Cleared by" is recorded when the bridge itself dismissed the alert, either from the Clear button or because the device was removed. Otherwise it reads "Acronis (console, or cleared by itself)".

## The Clear alert button

The card's button is an `Action.OpenUrl` to:

```
http://localhost:8765/clear?id=<alert ID>&k=<key>
```

On a server, `-ClearUrl` (env `ACRO_CLEAR_URL`) replaces that address with a public one, for example `https://alerts.example.com/acro-check/clear`. A reverse proxy forwards `/acro-check/` to the container's port 8765, which strips the prefix back to `/clear`.

The bridge runs a `System.Net.HttpListener` on `http://localhost:8765/`, or on `-Listen` (env `ACRO_LISTEN`). In the container that's `http://*:8765/`. Binding to `localhost` needs no admin rights. Between polls, `Wait-Next` waits on `GetContextAsync()` in 500 ms steps, so a click is answered within half a second.

A request is accepted only when all of these hold:

| Check | Why |
|---|---|
| Path is `/clear` | Nothing else is served |
| `k` matches the key in the state file | A random 32-character key made on first start, so only links the bridge made work |
| `id` is a GUID | No injection into the API path |
| The ID is in `open` | It only clears alerts it posted and that are still open |

A GET (or HEAD) answers with a confirm page: the alert's title and a **Clear alert** button, a form that POSTs back to the same URL. Only that POST dismisses the alert. Teams' link preview (user agent `SkypeUriPreview`) fetches every URL on a card 6 to 9 seconds after it posts; before this, that fetch counted as a click, and every alert was dismissed in Acronis seconds after its card posted.

On the POST it sends `DELETE /api/alert_manager/v1/alerts/{id}` and shows a small page that closes itself. It also runs a poll straight away, so the cleared card follows within seconds. If Acronis answers 404, the alert was already cleared, and the page says so.

Never call `DELETE /api/alert_manager/v1/alerts` without an ID: that dismisses every alert in the tenant.

## Removed devices

When a device is removed from Acronis, its open alerts stay open, with nothing left to fix and nothing to clear them.

Every alert carries `details.resourceId`. Each round, the bridge looks it up with `GET /api/resource_management/v4/resources/{resourceId}`:

| Answer | Meaning | Action |
|---|---|---|
| 200 | Device exists | Keep the alert. Remember the device as live for 5 minutes. |
| 404 `ResourceNotFound`, "resource deleted" | Device was removed | Dismiss the alert; the cleared card says "device X was removed from Acronis" |
| Anything else (timeout, 500) | Unknown | Keep the alert. Never dismiss on a guess. |

Alerts without a `resourceId` are left alone. In `-DryRun` it prints "would clear it" and dismisses nothing.

## Root cause on failed backups

A failed backup alert holds a chain of nested errors in `details.error`, each with a `text` and a `suberror`. The top layers are generic ("TOL: Failed to execute the command. Backing up"), and the real cause is the deepest layer with text.

`Get-RootError` walks the chain down to that layer. When a layer names a storage host (`fields.fesAddress`), it appends that too. So the card says:

```
error        DNS hostname resolution error (storage upgd24gtd.tempe:44445)
error code   MemoDnsError
```

instead of the raw `@{code=MemoDnsError; context=; ...}` that PowerShell prints for the `errorMessage` object.

`errorMessage.kbLink` is usually an object of knowledge-base lookup keys, not a link. It's shown only when it is a real `http(s)` URL.

## The status line

`Show-Status` writes the line with `-NoNewline`. `Clear-Status` returns to the start of the line with a carriage return, blanks it with spaces, and returns again. Anything that prints an event clears the status line first, so events land on their own lines and the status line sits below them.

The line is cut to the window width. A wrapped line can't be rewritten in place.

Colors follow Acronis's own severity:

| Severity | Window | Teams header | Emoji |
|---|---|---|---|
| critical, error | Red | Attention | 🔴 |
| warning | Yellow | Warning | 🟠 |
| information | Cyan | Accent | 🔵 |
| none open | Green | n/a | n/a |

Emoji are built from code points (`[char]::ConvertFromUtf32`), so the file is plain ASCII. Windows PowerShell 5.1 reads a UTF-8 file without a BOM as ANSI, which would mangle literal emoji.

## State file

`acronis-alert-bridge.state.json`, next to the script by default:

```json
{
  "posted":   ["<ID>|2026-11-14T23:02:30", "..."],
  "counts":   { "<ID>": 2 },
  "clearKey": "<32 hex characters>",
  "saved":    "2026-11-14T22:06:00.0000000Z"
}
```

It is written after every round, but not in `-DryRun`. Deleting it makes the next start a first start: existing alerts are marked as seen, the counts reset, and a new Clear key is made, so old cards' buttons stop working.
