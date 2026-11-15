# Acronis API notes

Behavior seen on the Acronis Cyber Protect Cloud APIs while building acro-check (November 2026, beta data center). The docs at developer.acronis.com don't state most of this.

## Alert Manager v1 (`/api/alert_manager/v1`)

| Call | Behavior |
|---|---|
| `GET /alerts` | Active alerts only, by default |
| `GET /alerts?show_deleted_only=true` | Cleared (dismissed) alerts only, each with `deletedAt` |
| `GET /alerts?show_deleted=true` | Both |
| `GET /alerts/{id}` | 404 for a cleared alert |
| `DELETE /alerts/{id}` | Dismisses one alert. 204 on success, 404 if already cleared |
| `DELETE /alerts` with no filter | **Dismisses every alert in the tenant.** Never call it without an ID. |

- **Repeats reuse the ID.** When a problem comes back, Acronis reopens the alert under the same `id` with a new `createdAt`. `receivedAt` keeps the first report time.
- **No repeat count.** No field counts how often an alert reopened.
- **Severity values:** `ok`, `information`, `warning`, `error`, `critical`. There is no "high". A disk speed anomaly is `warning` and a failed backup is `critical`.
- **Malware detections are `warning`.** All 17 seen in one tenant (`TotalProtectMalwareDetectedOAS` for real-time protection, `TotalProtectMalwareDetectedODS` for scans, category "Antimalware protection") were `warning`, the EICAR test file included, because the file was quarantined. A severity filter set to "error and up" silently drops every one. acro-check treats security categories and malware types as critical for that reason.
- **Device link:** `details.resourceId` (uppercase GUID) and `details.resourceName`.
- **Removed devices leave alerts open.** Removing a device doesn't clear its alerts.
- **Errors are nested.** `details.error` is a chain of `{ text, fields, suberror }`. The top layers are generic, and the deepest layer with text is the cause. `details.errorMessage` is an object (`code`, `reason`, `domain`, `kbLink`, `serCode`), not text.
- **Tenant on alerts.** `tenant.id` is a numeric ID and `tenant.uuid` is the GUID. Alerts on a user's own devices carry the user's personal tenant, which isn't in the customer tenant's `children` list.

## Resource Management v4 (`/api/resource_management/v4`)

| Call | Behavior |
|---|---|
| `GET /resources?type=resource.machine` | Registered machines |
| `GET /resources/{id}` | 200 with the resource, or 404 `ResourceNotFound` with message "resource deleted (...)" once it's removed |

## Tokens

- Client credentials token from `POST /api/2/idp/token`, then exchange it for a tenant-scoped token (JWT bearer grant, `scope=urn:acronis.com:tenant-id:{tenant}`). Alerts, resources and plans need the scoped token for full data.
- Tokens last 2 hours.

## PowerShell gotchas hit along the way

- PowerShell variable names are case-insensitive. A local `$owner` silently overwrites a `[string]$Owner` parameter.
- PowerShell 7's `ConvertFrom-Json` turns ISO dates into `DateTime`, while 5.1 leaves them as strings. Normalize before using a date as a key.
- Windows PowerShell 5.1 reads a UTF-8 script without a BOM as ANSI. Keep the script ASCII and build emoji from code points.

## A beta data center failure worth knowing

On the beta data center, cloud backups failed for a while with `MemoDnsError`, "DNS hostname resolution error". The agent was told to use the storage host `upgd24gtd.tempe:44445`. That isn't a public name, and it doesn't resolve on public DNS (tried on 1.1.1.1 and on a hosting provider's resolvers). It came and went: Hudson's failed backup cleared itself about 35 minutes later. This was on the Acronis side, not the network.
