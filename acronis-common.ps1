# Shared Acronis API helpers. Dot-source it:  . "$PSScriptRoot\acronis-common.ps1"
# Reads credentials from environment variables; never writes or prints a secret or token:
#   ACRONIS_BASE_URL, ACRONIS_CLIENT_ID, ACRONIS_CLIENT_SECRET

$ErrorActionPreference = "Stop"
if (-not (Get-Variable RawMode -Scope Script -ErrorAction SilentlyContinue)) { $script:RawMode = $false }

function Connect-Acronis {
  # Gets a client-credentials token, finds the API client's tenant, then trades the token for a
  # tenant-scoped one. The protection services (agents, resources, policies, alerts, tasks)
  # return full data only with the scoped token.
  foreach ($v in "ACRONIS_BASE_URL", "ACRONIS_CLIENT_ID", "ACRONIS_CLIENT_SECRET") {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Set the $v environment variable first." }
  }
  $script:dc   = $env:ACRONIS_BASE_URL.TrimEnd("/")
  $script:base = "$($script:dc)/api/2"
  $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:ACRONIS_CLIENT_ID):$($env:ACRONIS_CLIENT_SECRET)"))

  $tok = Invoke-RestMethod -Method Post -Uri "$($script:base)/idp/token" -Headers @{ Authorization = "Basic $basic" } `
    -ContentType "application/x-www-form-urlencoded" -Body "grant_type=client_credentials"
  $script:auth = @{ Authorization = "Bearer $($tok.access_token)" }

  $client = Invoke-RestMethod -Uri "$($script:base)/clients/$($env:ACRONIS_CLIENT_ID)" -Headers $script:auth
  $script:tenantId = $client.tenant_id
  $script:me = Invoke-RestMethod -Uri "$($script:base)/tenants/$($script:tenantId)" -Headers $script:auth

  $form = "grant_type=" + [uri]::EscapeDataString("urn:ietf:params:oauth:grant-type:jwt-bearer") +
          "&assertion=" + [uri]::EscapeDataString($tok.access_token) +
          "&scope=" + [uri]::EscapeDataString("urn:acronis.com:tenant-id:$($script:tenantId)")
  $scoped = Invoke-RestMethod -Method Post -Uri "$($script:base)/idp/token" -Headers @{ Authorization = "Basic $basic" } `
    -ContentType "application/x-www-form-urlencoded" -Body $form
  $script:auth = @{ Authorization = "Bearer $($scoped.access_token)" }

  Write-Host "Connected: $($script:me.name) [$($script:me.kind)] on $($script:dc)" -ForegroundColor Green
}

function Get-Api([string]$path, [hashtable]$query) {
  # One GET. Returns $null and prints a readable reason on failure, instead of stopping the run.
  $q = if ($query) { $query } else { @{} }
  $qs = ($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join "&"
  $uri = if ($qs) { "$($script:dc)$path`?$qs" } else { "$($script:dc)$path" }
  try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $script:auth
    if ($script:RawMode) {
      $json = $resp | ConvertTo-Json -Depth 8 -Compress
      if ($json.Length -gt 1500) { $json = $json.Substring(0, 1500) + " ...(cut)" }
      Write-Host "   GET $path`n   $json" -ForegroundColor DarkGray
    }
    return $resp
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Host "   GET $path skipped: HTTP $code $($_.ErrorDetails.Message)" -ForegroundColor DarkYellow
    return $null
  }
}

function Items($resp) {
  # The list in a response, without nulls: handles "items", "data", or a bare array.
  if ($null -eq $resp) { return @() }
  $list = if ($resp -is [array]) { $resp }
          elseif ($resp.PSObject.Properties.Name -contains "items") { $resp.items }
          elseif ($resp.PSObject.Properties.Name -contains "data") { $resp.data }
          else { @() }
  return @($list | Where-Object { $null -ne $_ })
}
