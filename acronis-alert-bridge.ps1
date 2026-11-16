<#
.SYNOPSIS
  Pushes new Acronis alerts to a Teams, Slack or Discord channel, and says when they clear.

.DESCRIPTION
  Acronis has no webhooks and Workflow Automation has no "call a URL" action, so alerts only
  leave the console by email or through a supported PSA. This script fills that gap: it polls
  the Alert Manager API, and posts each new alert to a channel's incoming webhook.

  When an alert it posted is cleared (in the console, by Acronis itself, or with the card's
  Clear alert button), it posts an "Alert cleared" message.

  The Clear alert button opens http://localhost:8765/clear on this machine, where this script
  listens, or -ClearUrl when it runs on a server behind a reverse proxy (see the Dockerfile).
  It dismisses that one alert through the API (DELETE /alerts/{id}). The link carries a random
  key kept in the state file, so nothing else can call it. The button works only while this
  script runs. The other write: alerts on a device removed from Acronis are dismissed.

  It remembers which alerts it has posted in acronis-alert-bridge.state.json, so a restart
  does not repost them.

  Webhook URL comes from -WebhookUrl or the ACRONIS_ALERT_WEBHOOK environment variable.
  Acronis credentials: same three environment variables as the other scripts.

.PARAMETER Target         teams | slack | discord   (shape of the message)
.PARAMETER MinSeverity    information | warning | error | critical   (default error: only error and critical reach the channel)
.PARAMETER Once           check one time and exit, instead of polling
.PARAMETER DryRun         print the message instead of posting it; the Clear button dismisses nothing
.PARAMETER Backfill       on first start, also post alerts that already exist (default: skip them)
.PARAMETER ClearPort      port for the Clear alert button (default 8765)
.PARAMETER ClearUrl       public URL of the Clear button, for a server (env ACRO_CLEAR_URL)
.PARAMETER Listen         listener prefix, http://*:8765/ in a container (env ACRO_LISTEN)
.PARAMETER NoClearButton  post cards without the Clear alert button

.EXAMPLE
  .\acronis-alert-bridge.ps1 -Target teams                 # poll every 15 s until Ctrl+C
  .\acronis-alert-bridge.ps1 -Target teams -Once -DryRun   # see what it would post
#>
[CmdletBinding()]
param(
  [ValidateSet("teams", "slack", "discord")] [string]$Target = "teams",
  [string]$WebhookUrl = $env:ACRONIS_ALERT_WEBHOOK,
  [ValidateSet("information", "warning", "error", "critical")] [string]$MinSeverity = "error",
  [int]$IntervalSeconds = 15,
  [string]$State = $env:ACRO_STATE,   # default: acronis-alert-bridge.state.json next to this script
  [int]$ClearPort = 8765,
  # Public address of the Clear button when the bridge runs on a server behind a reverse proxy,
  # e.g. https://alerts.example.com/acro-check/clear. Default: http://localhost:<ClearPort>/clear
  [string]$ClearUrl = $env:ACRO_CLEAR_URL,
  # What the listener binds. In a container: http://*:8765/. Default: http://localhost:<ClearPort>/
  [string]$Listen = $env:ACRO_LISTEN,
  [switch]$NoClearButton,
  [switch]$Once,
  [switch]$DryRun,
  [switch]$Backfill,
  [switch]$Raw
)

$script:RawMode = [bool]$Raw
if (-not $State) { $State = Join-Path $PSScriptRoot "acronis-alert-bridge.state.json" }   # $PSScriptRoot is empty in 5.1 param defaults
. (Join-Path $PSScriptRoot "acronis-common.ps1")   # also loads acro-check.env.ps1, if present
if (-not (Get-Command Connect-Acronis -ErrorAction SilentlyContinue)) { throw "acronis-common.ps1 did not load. Check it is next to this script." }
if (-not $WebhookUrl) { $WebhookUrl = $env:ACRONIS_ALERT_WEBHOOK }
if (-not $DryRun -and -not $WebhookUrl) { throw "Set -WebhookUrl or the ACRONIS_ALERT_WEBHOOK environment variable, or use -DryRun." }

$rank = @{ ok = 0; information = 1; warning = 2; error = 3; critical = 4 }
$minRank = $rank[$MinSeverity]
# Acronis sets the severity (a disk speed anomaly is "warning", a failed backup "critical").
# Colors follow it, except security detections, which count as critical (see Get-Sev).
$consoleColor = @{ critical = "Red"; error = "Red"; warning = "Yellow"; information = "Cyan"; ok = "Green" }
$cardColor    = @{ critical = "Attention"; error = "Attention"; warning = "Warning"; information = "Accent"; ok = "Good" }

# Acronis rates a malware detection it quarantined as "warning" (every one seen so far:
# TotalProtectMalwareDetectedOAS/ODS, category "Antimalware protection"). A detection is never
# a routine warning, so security alerts count as critical for the filter and the colors.
function Test-Security($a) {
  ([string]$a.category -match 'Antimalware|Active Protection|Security') -or
  ([string]$a.type -match 'Malware|Ransomware|Cryptomin|Exploit|Threat')
}
function Get-Sev($a) {
  $s = [string]$a.severity
  if ((Test-Security $a) -and $rank[$s] -lt $rank["critical"]) { return "critical" }
  return $s
}

# ---------------------------------------------------------------------------
# State: alert ids already posted, and the key that guards the Clear button
# ---------------------------------------------------------------------------
# Acronis reopens a cleared alert under the same id when the problem comes back, with a new
# createdAt. So "posted" is keyed by id + createdAt (one occurrence), not by id alone.
function Get-Key($a) {
  $c = $a.createdAt
  $s = if ($c -is [datetime]) { $c.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") } else { ([string]$c).Substring(0, [Math]::Min(19, ([string]$c).Length)) }
  "$(([string]$a.id).ToUpperInvariant())|$s"
}
$posted = @{}      # occurrence keys already posted
$counts = @{}      # id -> how many occurrences of it the bridge has seen (Acronis keeps no count)
$script:countedKeys = @{}
$open = @{}        # posted alerts still active: id -> alert. Watched for clearing.
$clearedBy = @{}   # id -> who cleared it, when the Clear button did it
$clearKey = $null
$firstRun = -not (Test-Path $State)
if (-not $firstRun) {
  $saved = Get-Content $State -Raw | ConvertFrom-Json
  foreach ($i in @($saved.posted)) {
    if (-not $i) { continue }
    $posted[[string]$i] = $true
    $pid0 = ([string]$i).Split("|")[0].ToUpperInvariant()   # older state files hold bare ids: count each as seen once
    if (-not $counts[$pid0]) { $counts[$pid0] = 1 }
  }
  if ($saved.counts) { foreach ($p in $saved.counts.PSObject.Properties) { $counts[$p.Name] = [int]$p.Value } }
  $clearKey = [string]$saved.clearKey
}
if (-not $clearKey) { $clearKey = [guid]::NewGuid().ToString("N") }
function Save-State { @{ posted = @($posted.Keys); counts = $counts; clearKey = $clearKey; saved = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content $State -Encoding utf8 }

$useButton = -not $NoClearButton -and -not $Once
$clearBase = if ($ClearUrl) { $ClearUrl.TrimEnd("/") } else { "http://localhost:$ClearPort/clear" }
if (-not $Listen) { $Listen = "http://localhost:$ClearPort/" }

# ---------------------------------------------------------------------------
# Message shapes
# ---------------------------------------------------------------------------
function Get-Detail($a, [string]$key) { if ($a.details) { $a.details.$key } }
function Get-When($t) { try { ([datetime]$t).ToLocalTime().ToString("g") } catch { [string]$t } }
function Get-TenantName($a) { if ($tenantNames[[string]$a.tenant.uuid]) { $tenantNames[[string]$a.tenant.uuid] } else { [string]$a.tenant.id } }
function Get-RootError($a) {
  # A failed backup carries a chain of nested errors (details.error.suberror...). The deepest
  # one with text is the real cause, e.g. "DNS hostname resolution error" under four layers of
  # "Failed to execute the command". Storage-side errors also name the storage host (fesAddress).
  $e = $a.details.error; $text = $null; $where = $null
  while ($e -and $e.text) {
    $text = [string]$e.text
    if ($e.fields -and $e.fields.fesAddress) { $where = [string]$e.fields.fesAddress }
    $e = $e.suberror
  }
  if ($text -and $where) { "$text (storage $where)" } else { $text }
}

function Get-Facts($a) {
  # The fields that matter to a technician, from whatever this alert type carries.
  $facts = [ordered]@{}
  foreach ($k in "resourceName", "planName", "fileName", "threatName", "path", "action") {
    $v = Get-Detail $a $k
    if ($v) { $facts[$k] = [string]$v }
  }
  # errorMessage is an object ({code, reason, kbLink, ...}), not text: show the cause and the code.
  $root = Get-RootError $a
  if ($root) { $facts["error"] = $root }
  $em = Get-Detail $a "errorMessage"
  if ($em -is [string]) { if ($em) { $facts["error code"] = $em } }
  elseif ($em) {
    $code = if ($em.reason) { [string]$em.reason } else { [string]$em.code }
    if ($code) { $facts["error code"] = $code }
    if ($em.kbLink -is [string] -and $em.kbLink -match '^https?://') { $facts["help"] = $em.kbLink }   # often an object of KB lookup keys, not a link
  }
  $facts["severity"] = if ((Get-Sev $a) -ne [string]$a.severity) { "$($a.severity) in Acronis, sent as critical (security detection)" } else { [string]$a.severity }
  $facts["category"] = [string]$a.category
  $facts["raised"]   = Get-When $a.createdAt
  $n = $counts[([string]$a.id).ToUpperInvariant()]
  if ($n -gt 1) {
    $facts["times seen"] = [string]$n
    if ($a.receivedAt) { $facts["first reported"] = Get-When $a.receivedAt }   # Acronis keeps the first report time
  }
  $facts["tenant"]   = Get-TenantName $a
  return $facts
}
$plainTitle = @{
  TotalProtectMalwareDetectedOAS = "Malware blocked (real-time protection)"
  TotalProtectMalwareDetectedODS = "Malware found (scheduled scan)"
}
function Get-Title($a) {
  $what = if (Get-Detail $a "title") { Get-Detail $a "title" }
          elseif ($plainTitle[[string]$a.type]) { $plainTitle[[string]$a.type] }
          else { ([string]$a.type) -creplace '([a-z])([A-Z])', '$1 $2' }
  $where = Get-Detail $a "resourceName"
  if ($where) { "$what on $where" } else { $what }
}
function Get-ClearUrl($a) { "$clearBase`?id=$([string]$a.id)&k=$clearKey" }
function Get-Emoji([int]$cp) { [char]::ConvertFromUtf32($cp) }   # code points, so Windows PowerShell 5.1 reads this file correctly

function New-Payload($a) {
  $title = Get-Title $a
  $facts = Get-Facts $a
  $dot = @{ critical = 0x1F534; error = 0x1F534; warning = 0x1F7E0; information = 0x1F535; ok = 0x1F7E2 }[(Get-Sev $a)]
  $sevEmoji = if ($dot) { Get-Emoji $dot } else { "" }
  $n = $counts[([string]$a.id).ToUpperInvariant()]
  $label = if ($n -gt 1) { "Acronis alert, repeat ($n times)" } else { "Acronis alert" }
  switch ($Target) {
    "teams" {
      # Adaptive Card, the format Teams "Workflows" webhooks accept.
      $actions = @()
      if ($useButton) { $actions += @{ type = "Action.OpenUrl"; title = "Clear alert"; url = (Get-ClearUrl $a) } }
      $actions += @{ type = "Action.OpenUrl"; title = "Open the console"; url = $script:dc }
      $card = @{
        type = "AdaptiveCard"; version = "1.4"; '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
        body = @(
          @{ type = "TextBlock"; text = "$sevEmoji $label"; size = "Small"; weight = "Bolder"; color = $cardColor[(Get-Sev $a)] },
          @{ type = "TextBlock"; text = $title; size = "Large"; weight = "Bolder"; wrap = $true },
          @{ type = "FactSet"; facts = @($facts.GetEnumerator() | ForEach-Object { @{ title = $_.Key; value = $_.Value } }) }
        )
        actions = $actions
      }
      return @{ type = "message"; attachments = @(@{ contentType = "application/vnd.microsoft.card.adaptive"; content = $card }) }
    }
    "slack" {
      $lines = ($facts.GetEnumerator() | ForEach-Object { "*$($_.Key):* $($_.Value)" }) -join "`n"
      $links = "<$($script:dc)|Open the console>"
      if ($useButton) { $links = "<$(Get-ClearUrl $a)|Clear alert>  |  $links" }
      return @{ text = "$sevEmoji ${label}: $title"; blocks = @(
        @{ type = "header"; text = @{ type = "plain_text"; text = "$sevEmoji $title" } },
        @{ type = "section"; text = @{ type = "mrkdwn"; text = $lines } },
        @{ type = "context"; elements = @(@{ type = "mrkdwn"; text = $links }) }) }
    }
    "discord" {
      $color = @{ critical = 13250098; error = 13250098; warning = 15898933; information = 3112182; ok = 954509 }[(Get-Sev $a)]
      return @{ username = "Acronis alerts"; embeds = @(@{
        title = $title; url = $script:dc; color = $color
        fields = @($facts.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value; inline = $true } }) }) }
    }
  }
}

function New-ClearedPayload($a, $deletedAt, [string]$by) {
  $title = Get-Title $a
  $facts = [ordered]@{}
  $facts["cleared"] = Get-When $deletedAt
  $facts["cleared by"] = $by
  try {
    $span = ([datetime]$deletedAt) - ([datetime]$a.createdAt)
    $facts["open for"] = if ($span.TotalHours -ge 1) { "{0} h {1} min" -f [int][math]::Floor($span.TotalHours), $span.Minutes } else { "{0} min {1} s" -f $span.Minutes, $span.Seconds }
  } catch { }
  $facts["tenant"] = Get-TenantName $a
  $check = Get-Emoji 0x2705
  switch ($Target) {
    "teams" {
      $card = @{
        type = "AdaptiveCard"; version = "1.4"; '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
        body = @(
          @{ type = "TextBlock"; text = "$check Acronis alert cleared"; size = "Small"; weight = "Bolder"; color = "Good" },
          @{ type = "TextBlock"; text = $title; size = "Large"; weight = "Bolder"; wrap = $true },
          @{ type = "FactSet"; facts = @($facts.GetEnumerator() | ForEach-Object { @{ title = $_.Key; value = $_.Value } }) }
        )
        actions = @(@{ type = "Action.OpenUrl"; title = "Open the console"; url = $script:dc })
      }
      return @{ type = "message"; attachments = @(@{ contentType = "application/vnd.microsoft.card.adaptive"; content = $card }) }
    }
    "slack" {
      $lines = ($facts.GetEnumerator() | ForEach-Object { "*$($_.Key):* $($_.Value)" }) -join "`n"
      return @{ text = "$check Acronis alert cleared: $title"; blocks = @(
        @{ type = "header"; text = @{ type = "plain_text"; text = "$check Cleared: $title" } },
        @{ type = "section"; text = @{ type = "mrkdwn"; text = $lines } }) }
    }
    "discord" {
      return @{ username = "Acronis alerts"; embeds = @(@{
        title = "Cleared: $title"; url = $script:dc; color = 954509
        fields = @($facts.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value; inline = $true } }) }) }
    }
  }
}

function Send-Payload($payload) {
  $body = $payload | ConvertTo-Json -Depth 12
  if ($DryRun) { Write-Host "`n--- would post to $Target ---`n$body" -ForegroundColor DarkGray; return $true }
  try {
    Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType "application/json; charset=utf-8" `
      -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    return $true
  } catch {
    Write-Host "   post failed: $($_.Exception.Message) $($_.ErrorDetails.Message)" -ForegroundColor Red
    return $false
  }
}

# ---------------------------------------------------------------------------
# Poll: post new alerts, then post "cleared" for posted alerts that are gone
# ---------------------------------------------------------------------------
function Connect-AndName {
  Connect-Acronis
  $script:connectedAt = Get-Date
  $script:tenantNames = @{ [string]$script:tenantId = $script:me.name }
  foreach ($k in @(Items (Get-Api "/api/2/tenants/$($script:tenantId)/children" @{ include_details = "true" }))) { $script:tenantNames[[string]$k.id] = $k.name }
}

# One status line, rewritten in place each round, so a quiet window stays quiet.
# Anything worth reading (posted, cleared, errors) clears it first and prints on its own line.
# With no terminal (docker logs, a service, a redirect) a line can't be rewritten, so the status
# prints as a normal line, and only when it changes (the "Checked" time aside).
$script:statusLen = 0; $script:statusText = ""; $script:statusColor = "Green"; $script:lastStatus = ""
$script:plainLog = $false; try { $script:plainLog = [Console]::IsOutputRedirected } catch { }
function Clear-Status {
  if ($script:statusLen) { Write-Host ("`r" + (" " * $script:statusLen) + "`r") -NoNewline; $script:statusLen = 0 }
}
function Show-Status([string]$text, [string]$color = "Green") {
  if ($script:plainLog) {
    $k = $text -replace '\s*Checked .*$', ''
    if ($k -ne $script:lastStatus) { Write-Host "$(Get-Date -Format T)  $k"; $script:lastStatus = $k }
    $script:statusText = $text; $script:statusColor = $color
    return
  }
  Clear-Status
  # Keep it on one line: a wrapped line can't be rewritten in place.
  try { $w = [Console]::WindowWidth - 1; if ($w -gt 10 -and $text.Length -gt $w) { $text = $text.Substring(0, $w) } } catch { }
  Write-Host $text -NoNewline -ForegroundColor $color
  $script:statusText = $text; $script:statusColor = $color; $script:statusLen = $text.Length
}

# Orphaned alerts: when a device is removed from Acronis, its open alerts stay open with
# nothing left to fix. The bridge looks up each alert's device (details.resourceId); a 404
# ResourceNotFound means the device was removed, so the bridge dismisses the alert itself.
# Devices found alive are remembered for 5 minutes to keep the lookups cheap.
$script:liveRes = @{}; $script:liveResAt = Get-Date
function Test-DeviceRemoved($a) {
  $rid = [string]$a.details.resourceId
  if (-not $rid) { return $false }
  if (((Get-Date) - $script:liveResAt).TotalMinutes -gt 5) { $script:liveRes = @{}; $script:liveResAt = Get-Date }
  if ($script:liveRes[$rid]) { return $false }
  try {
    Invoke-RestMethod -Uri "$($script:dc)/api/resource_management/v4/resources/$rid" -Headers $script:auth | Out-Null
    $script:liveRes[$rid] = $true; return $false
  } catch {
    return ($_.Exception.Response.StatusCode.value__ -eq 404)   # anything else (timeout, 500): assume it still exists
  }
}

function Clear-Orphans($alerts) {
  # Returns the alerts that still belong to a device; dismisses the rest.
  $keep = @()
  foreach ($a in $alerts) {
    if (-not (Test-DeviceRemoved $a)) { $keep += $a; continue }
    $id = ([string]$a.id).ToUpperInvariant()
    $dev = [string]$a.details.resourceName
    if ($DryRun) { Write-Host "$(Get-Date -Format T)  dry run: $(Get-Title $a) belongs to removed device $dev, would clear it" -ForegroundColor Yellow; continue }
    try {
      Invoke-RestMethod -Method Delete -Uri "$($script:dc)/api/alert_manager/v1/alerts/$id" -Headers $script:auth | Out-Null
      $clearedBy[$id] = "the bridge: device $dev was removed from Acronis"
      Write-Host "$(Get-Date -Format T)  auto-cleared: $(Get-Title $a)  (device $dev was removed)" -ForegroundColor Yellow
    } catch {
      if ($_.Exception.Response.StatusCode.value__ -ne 404) { Write-Host "   auto-clear failed: $($_.Exception.Message)" -ForegroundColor Red; $keep += $a }
    }
  }
  return $keep
}

function Invoke-Poll {
  Clear-Status
  if (((Get-Date) - $script:connectedAt).TotalMinutes -gt 100) { Connect-AndName }   # tokens last 2 h

  $resp = Get-Api "/api/alert_manager/v1/alerts" @{ order = "desc(created_at)"; limit = 100 }
  if ($null -eq $resp) { return }   # API hiccup: try again next round, and don't mistake it for "all cleared"
  $alerts = @(Clear-Orphans @(Items $resp))
  $active = @{}
  foreach ($a in $alerts) { $active[[string]$a.id] = $a }
  $new = @($alerts | Where-Object { -not $posted[(Get-Key $_)] -and $rank[(Get-Sev $_)] -ge $minRank })

  # Count each new occurrence once, before its card is built (the card shows the count).
  # A failed post is retried next round; $countedKeys stops it being counted twice.
  foreach ($a in $new) {
    $k = Get-Key $a
    if ($script:countedKeys[$k]) { continue }
    $cid = ([string]$a.id).ToUpperInvariant(); $counts[$cid] = [int]$counts[$cid] + 1
    $script:countedKeys[$k] = $true
  }

  if ($script:firstRun -and -not $Backfill) {
    foreach ($a in $new) { $posted[(Get-Key $a)] = $true }
    Write-Host "$(Get-Date -Format T)  first start: $($new.Count) existing alert(s) marked as seen, not posted (use -Backfill to post them)"
    $script:firstRun = $false
  } else {
    foreach ($a in ($new | Sort-Object createdAt)) {
      if (Send-Payload (New-Payload $a)) {
        $posted[(Get-Key $a)] = $true
        $open[[string]$a.id] = $a
        $c = $consoleColor[(Get-Sev $a)]; if (-not $c) { $c = "Cyan" }
        Write-Host "$(Get-Date -Format T)  posted: [$(Get-Sev $a)] $(Get-Title $a)" -ForegroundColor $c
      }
    }
  }

  # Posted alerts that are no longer active: confirm in the dismissed list, then post "cleared".
  $gone = @($open.Keys | Where-Object { -not $active.ContainsKey($_) })
  $clearedNow = 0
  if ($gone.Count) {
    $dismissed = @(Items (Get-Api "/api/alert_manager/v1/alerts" @{ show_deleted_only = "true"; order = "desc(deleted_at)"; limit = 100 }))
    foreach ($d in $dismissed) {
      $id = [string]$d.id
      if (-not $open.ContainsKey($id)) { continue }
      $by = if ($clearedBy[$id]) { $clearedBy[$id] } else { "Acronis (console, or cleared by itself)" }
      if (Send-Payload (New-ClearedPayload $open[$id] $d.deletedAt $by)) {
        Write-Host "$(Get-Date -Format T)  cleared: $(Get-Title $open[$id])  (by $by)" -ForegroundColor Green
        $open.Remove($id); $clearedBy.Remove($id); $clearedNow++
      }
    }
  }

  if (-not $DryRun) { Save-State }
  # Status line: green "Ready" when nothing is open, else the count in the color of the worst open alert.
  $at = Get-Date -Format T
  # Alerts below -MinSeverity are counted here but never sent to the channel.
  $sent  = @($alerts | Where-Object { $rank[(Get-Sev $_)] -ge $minRank })
  $below = @($alerts | Where-Object { $rank[(Get-Sev $_)] -lt $minRank })
  $pick  = if ($sent.Count) { $sent } else { $below }
  $worst = if ($pick.Count) { Get-Sev @($pick | Sort-Object { $rank[(Get-Sev $_)] } -Descending)[0] } else { "" }
  $c = $consoleColor[$worst]; if (-not $c) { $c = "Green" }
  if ($sent.Count)      { Show-Status "Status: $($sent.Count) open ($worst). Nothing new. Checked $at" $c }
  elseif ($below.Count) { Show-Status "Status: Ready. $($below.Count) $worst open, not sent. Checked $at" $c }
  else                  { Show-Status "Status: Ready. No open alerts. Checked $at" "Green" }
}

# ---------------------------------------------------------------------------
# Clear alert button: a listener on localhost that dismisses one posted alert
# ---------------------------------------------------------------------------
function Send-Page($ctx, [int]$code, [string]$heading, [string]$text, [string]$extra = "", [bool]$autoClose = $true) {
  $html = "<!doctype html><meta charset=utf-8><title>Acronis alert bridge</title>" +
          "<body style='font-family:Segoe UI,sans-serif;background:#f4f6f8;color:#1b2733;display:grid;place-items:center;height:100vh;margin:0'>" +
          "<div style='background:#fff;padding:32px 40px;border-radius:12px;box-shadow:0 2px 12px #0001;max-width:520px'>" +
          "<h1 style='margin:0 0 8px;font-size:22px'>$heading</h1><p style='margin:0;font-size:16px;line-height:1.5'>$text</p>$extra</div>" +
          $(if ($autoClose) { "<script>setTimeout(function(){window.close()},2500)</script>" } else { "" })
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = "text/html; charset=utf-8"
  if ($ctx.Request.HttpMethod -ne "HEAD") {
    $bytes = [Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  }
  $ctx.Response.Close()
}

function Invoke-ClearRequest($ctx) {
  Clear-Status
  $q = $ctx.Request.QueryString
  $id = ([string]$q["id"]).ToUpperInvariant()
  if ($ctx.Request.Url.AbsolutePath -ne "/clear" -or $q["k"] -ne $clearKey -or $id -notmatch '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$') {
    Send-Page $ctx 404 "Not found" "This link isn't one the alert bridge made."; return
  }
  if (-not $open.ContainsKey($id)) { Send-Page $ctx 200 "Already cleared" "This alert is already cleared, or it isn't one the bridge posted."; return }

  # Only a POST dismisses. Teams' link preview (SkypeUriPreview) fetches every card URL seconds after
  # posting; a GET or HEAD gets the confirm page, so only a person pressing the button clears the alert.
  if ($ctx.Request.HttpMethod -ne "POST") {
    $title = [System.Net.WebUtility]::HtmlEncode((Get-Title $open[$id]))
    $form = "<form method='post' style='margin-top:24px'><button type='submit' style='font:600 16px Segoe UI,sans-serif;" +
            "background:#c4314b;color:#fff;border:0;border-radius:8px;padding:10px 22px;cursor:pointer'>Clear alert</button></form>"
    Send-Page $ctx 200 "Clear this alert?" "<b>$title</b><br>Pressing the button dismisses it in Acronis." $form $false
    return
  }

  if ($DryRun) {
    Write-Host "$(Get-Date -Format T)  dry run: Clear alert clicked for $id, nothing dismissed" -ForegroundColor Yellow
    Send-Page $ctx 200 "Dry run" "The button works. In a dry run nothing is dismissed."; return
  }
  try {
    Invoke-RestMethod -Method Delete -Uri "$($script:dc)/api/alert_manager/v1/alerts/$id" -Headers $script:auth | Out-Null
    $clearedBy[$id] = "the Clear alert button in $Target, through the API"
    Write-Host "$(Get-Date -Format T)  Clear alert clicked: dismissed $id in Acronis" -ForegroundColor Yellow
    Send-Page $ctx 200 "Alert cleared in Acronis" "The cleared message is on its way to the channel. You can close this tab."
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 404) { Send-Page $ctx 200 "Already cleared" "Acronis had already dismissed this alert."; return }
    Write-Host "   dismiss failed: HTTP $code $($_.ErrorDetails.Message)" -ForegroundColor Red
    Send-Page $ctx 502 "Couldn't clear it" "Acronis answered HTTP $code. Check the bridge window."; return
  }
  Invoke-Poll   # post the cleared message now, not on the next round
}

function Wait-Next {
  # Sleeps until the next poll, answering Clear alert clicks while it waits.
  $until = (Get-Date).AddSeconds($IntervalSeconds)
  while ((Get-Date) -lt $until) {
    if (-not $script:listener) { Start-Sleep -Milliseconds 500; continue }
    if (-not $script:pending) { $script:pending = $script:listener.GetContextAsync() }
    if ($script:pending.Wait(500)) {
      $ctx = $script:pending.Result; $script:pending = $null
      try { Invoke-ClearRequest $ctx } catch { Clear-Status; Write-Host "   clear request failed: $($_.Exception.Message)" -ForegroundColor Red }
      if (-not $script:statusLen -and $script:statusText) { Show-Status $script:statusText $script:statusColor }   # put the status line back
    }
  }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
Connect-AndName

# Alerts posted before this start that are still active: watch them for clearing too.
foreach ($a in @(Items (Get-Api "/api/alert_manager/v1/alerts" @{ order = "desc(created_at)"; limit = 100 }))) {
  if ($posted[(Get-Key $a)]) { $open[[string]$a.id] = $a }
}

$script:listener = $null
if ($useButton) {
  $script:listener = [System.Net.HttpListener]::new()
  $script:listener.Prefixes.Add($Listen)
  try { $script:listener.Start() }
  catch {
    Write-Host "Clear alert button off: can't listen on $Listen ($($_.Exception.Message)). Is another bridge running?" -ForegroundColor DarkYellow
    $script:listener = $null; $useButton = $false
  }
}

$mode = if ($DryRun) { "dry run, nothing posted" } else { "posting to $Target" }
$btn = if ($useButton) { "Clear alert button on ($clearBase)" } else { "no Clear alert button" }
Write-Host "Alert bridge: $mode, severity $MinSeverity and up, every $IntervalSeconds s, $btn. Watching $($open.Count) posted alert(s) for clearing. Ctrl+C to stop." -ForegroundColor Green

try {
  while ($true) {
    Invoke-Poll
    if ($Once) { break }
    Wait-Next
  }
} finally {
  if ($script:statusLen) { Write-Host "" }   # end the status line so the prompt starts clean
  if ($script:listener) { $script:listener.Stop(); $script:listener.Close() }
}
