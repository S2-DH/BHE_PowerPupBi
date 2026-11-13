# ===================================================================
# Get-BHEAuditLog.ps1
# ===================================================================
# Pulls /api/v2/audit - the tenant's audit trail (logins, changes,
# certifications, token activity, etc.) - and keeps the most recent
# 50 entries for a "what just happened" table widget.
#
# CONFIRMED field names (from SpecterOps' published API reference,
# not assumed): each log entry is
#   id, created_at, actor_id, actor_name, actor_email, action,
#   fields (free-form object, schema not fixed), request_id,
#   source_ip_address, commit_id, status (intent|success|failure)
# Response shape: { "data": { "logs": [ ... ] } }
#
# The API supports server-side sort + limit, so this asks for the
# newest 50 directly (sort_by=-created_at&limit=50) rather than
# pulling everything and sorting client-side.
#
# A RecencyBucket + DaysAgo column is added so Power BI conditional
# formatting (Today / Past 7 Days / Older) can key off a plain
# field instead of recomputing dates in DAX.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder,
    [int]$Limit = 50
)

$ErrorActionPreference = "Stop"
if (-not $OutputFolder) {
    $OutputFolder = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { Join-Path (Get-Location) "Data" }
}

if (-not $EnvPath) {
    if ($PSScriptRoot) { $EnvPath = Join-Path $PSScriptRoot ".env" } else { $EnvPath = Join-Path (Get-Location) ".env" }
}

function Import-DotEnv {
    param([string]$Path)
    $v = @{}
    foreach ($line in Get-Content -Path $Path) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        if ($t.StartsWith("export ")) { $t = $t.Substring(7).Trim() }
        $i = $t.IndexOf("="); if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim(); $val = $t.Substring($i + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) { $val = $val.Substring(1, $val.Length - 2) }
        $v[$k] = $val
    }
    return $v
}

if (-not (Test-Path $EnvPath)) { Write-Host "[FAIL] .env not found at $EnvPath" -ForegroundColor Red; exit 1 }
$e = Import-DotEnv -Path $EnvPath
$restEndpoint = $e["BHE_API_URL"]; $tokenId = $e["BHE_TOKEN_ID"]; $tokenKey = $e["BHE_TOKEN_KEY"]
if (-not $restEndpoint -or -not $tokenId -or -not $tokenKey) { Write-Host "[FAIL] .env missing keys" -ForegroundColor Red; exit 1 }
if (-not $restEndpoint.StartsWith("http")) { $restEndpoint = "https://$restEndpoint" }
$restEndpoint = $restEndpoint.TrimEnd('/')

function Get-BHEHMACSignature {
    param([string]$TokenId, [string]$TokenKey, [string]$Method, [string]$Uri)
    $ep = ([System.Uri]$Uri).PathAndQuery
    $ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss+00:00")
    $dk = $ts.Substring(0, 13)
    $a = New-Object System.Security.Cryptography.HMACSHA256; $a.Key = [Text.Encoding]::UTF8.GetBytes($TokenKey)
    $h1 = $a.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Method$ep"))
    $b = New-Object System.Security.Cryptography.HMACSHA256; $b.Key = $h1
    $h2 = $b.ComputeHash([Text.Encoding]::UTF8.GetBytes($dk))
    $c = New-Object System.Security.Cryptography.HMACSHA256; $c.Key = $h2
    $h3 = $c.ComputeHash([Text.Encoding]::UTF8.GetBytes(""))
    return @{ "Authorization" = "bhesignature $TokenId"; "RequestDate" = $ts; "Signature" = [Convert]::ToBase64String($h3); "Content-Type" = "application/json" }
}

function Invoke-BHERequest {
    param([string]$Path)
    $url = "$restEndpoint$Path"
    $hdr = Get-BHEHMACSignature -TokenId $tokenId -TokenKey $tokenKey -Method "GET" -Uri $url
    return Invoke-RestMethod -Uri $url -Method GET -Headers $hdr -TimeoutSec 60 -ErrorAction Stop
}

function Get-Prop {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) { $p = $Obj.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne "") { return $p.Value } }
    return $null
}

$RawDir = Join-Path $OutputFolder "raw"
foreach ($d in @($OutputFolder, $RawDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$fileStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Audit Log (last $Limit)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

try {
    $resp = Invoke-BHERequest -Path "/api/v2/audit?limit=$Limit&sort_by=-created_at"
} catch {
    Write-Host ("  [FAIL] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$resp | ConvertTo-Json -Depth 12 | Out-File (Join-Path $RawDir "audit-log_$fileStamp.json") -Encoding UTF8

$logList = if ($resp.data.logs) { $resp.data.logs } elseif ($resp.data) { $resp.data } else { $resp }
if (-not $logList) { Write-Host "  [WARN] No audit entries returned - check raw\audit-log_$fileStamp.json" -ForegroundColor DarkYellow; exit 0 }

$rows = New-Object System.Collections.ArrayList
$now = Get-Date
$today = $now.Date

foreach ($l in $logList) {
    $createdAt = Get-Prop $l @('created_at')

    $daysAgo = $null
    $recency = "Older"
    if ($createdAt) {
        try {
            $createdLocal = ([DateTime]$createdAt).ToLocalTime()
            $daysAgo = [math]::Floor(($today - $createdLocal.Date).TotalDays)
            if ($daysAgo -le 0) { $recency = "Today" }
            elseif ($daysAgo -le 7) { $recency = "Past 7 Days" }
            else { $recency = "Older" }
        } catch {}
    }

    $actorName  = Get-Prop $l @('actor_name')
    $actorEmail = Get-Prop $l @('actor_email')
    $actor      = if ($actorName) { $actorName } elseif ($actorEmail) { $actorEmail } else { "(system)" }

    [void]$rows.Add([pscustomobject][ordered]@{
        CreatedAt    = $createdAt
        DateTimeUtc  = if ($createdAt) { ([DateTime]$createdAt).ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        Actor        = $actor
        ActorEmail   = $actorEmail
        Action       = Get-Prop $l @('action')
        Status       = Get-Prop $l @('status')
        SourceIp     = Get-Prop $l @('source_ip_address')
        DaysAgo      = $daysAgo
        RecencyBucket = $recency
        Id           = Get-Prop $l @('id')
        RequestId    = Get-Prop $l @('request_id')
    })
}

# newest first, capped to $Limit as a safety net even if the API ignores sort_by
$rows = $rows | Sort-Object { [DateTime]$_.CreatedAt } -Descending | Select-Object -First $Limit

$outFile = Join-Path $OutputFolder "audit-log.csv"
$rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] audit-log.csv ({0} rows)" -f $rows.Count) -ForegroundColor Cyan

$byBucket = $rows | Group-Object RecencyBucket | Sort-Object Name
foreach ($g in $byBucket) { Write-Host ("  [INFO] {0,-12} {1,3} entries" -f $g.Name, $g.Count) -ForegroundColor Gray }

$failures = @($rows | Where-Object { $_.Status -eq "failure" }).Count
if ($failures -gt 0) { Write-Host ("  [WARN] {0} failure-status entries in this window" -f $failures) -ForegroundColor DarkYellow }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $outFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
