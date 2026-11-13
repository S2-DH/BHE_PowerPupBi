# ===================================================================
# Get-BHETokens.ps1
# ===================================================================
# Pulls /api/v2/tokens - API token inventory for the tenant.
#
# CONFIRMED (from raw JSON, not assumed): the API returns expires_at
# and deleted_at as Go-style nullable timestamps: {"Time": ..., "Valid": bool}.
# Both are unwrapped into flat columns below.
#
# expires_at is REAL but shared across every token - same value
# regardless of each token's own creation date. It reflects a
# tenant-wide credential/signing-key rotation deadline, not an
# individual "this token expires on X" setting made at creation.
# Confirmed by checking two separate pulls hours apart: the value
# didn't change, so it's a fixed stored date, not recalculated live.
#
# deleted_at.Valid = true means the token has been revoked but is
# still returned by the list endpoint - surfaced here as IsRevoked.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder
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
Write-Host " BHE API Tokens" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

try {
    $resp = Invoke-BHERequest -Path "/api/v2/tokens"
} catch {
    Write-Host ("  [FAIL] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$resp | ConvertTo-Json -Depth 12 | Out-File (Join-Path $RawDir "tokens_$fileStamp.json") -Encoding UTF8

$tokenList = if ($resp.data.tokens) { $resp.data.tokens } elseif ($resp.data) { $resp.data } else { $resp }
if (-not $tokenList) { Write-Host "  [WARN] No tokens returned - check raw\tokens_$fileStamp.json" -ForegroundColor DarkYellow; exit 0 }

$rows = New-Object System.Collections.ArrayList
$now = Get-Date

foreach ($t in $tokenList) {
    $createdAt = Get-Prop $t @('created_at')
    $lastAccess = Get-Prop $t @('last_access', 'last_used')

    # expires_at / deleted_at are Go-style nullable timestamps: {Time, Valid}.
    # Valid=false means "not set" - Time will be a zero-value placeholder, ignore it.
    $expiresAtRaw = $t.expires_at
    $expiresAt = if ($expiresAtRaw -and $expiresAtRaw.Valid) { $expiresAtRaw.Time } else { $null }

    $deletedAtRaw = $t.deleted_at
    $isRevoked = [bool]($deletedAtRaw -and $deletedAtRaw.Valid)
    $revokedAt = if ($isRevoked) { $deletedAtRaw.Time } else { $null }

    $ageDays = $null
    if ($createdAt) { try { $ageDays = [math]::Round(($now - [DateTime]$createdAt).TotalDays) } catch {} }
    $daysSinceUse = $null
    if ($lastAccess) { try { $daysSinceUse = [math]::Round(($now - [DateTime]$lastAccess).TotalDays) } catch {} }
    $daysUntilExpiry = $null
    if ($expiresAt) { try { $daysUntilExpiry = [math]::Round(([DateTime]$expiresAt - $now).TotalDays) } catch {} }

    [void]$rows.Add([pscustomobject][ordered]@{
        SnapshotDate    = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Id              = Get-Prop $t @('id')
        Name            = if (Get-Prop $t @('token_name', 'name')) { Get-Prop $t @('token_name', 'name') } else { "(collector/service token)" }
        UserId          = if (Get-Prop $t @('user_id')) { Get-Prop $t @('user_id') } else { "N/A - no associated user" }
        CreatedAt       = $createdAt
        AgeDays         = $ageDays
        LastAccess      = $lastAccess
        DaysSinceUse    = $daysSinceUse
        ExpiresAt       = $expiresAt        # NOTE: identical across all tokens - reflects a shared/tenant-wide credential
        DaysUntilExpiry = $daysUntilExpiry  # rotation deadline, not an individual per-token expiry set at creation
        IsRevoked       = $isRevoked
        RevokedAt       = $revokedAt
    })
}

$outFile = Join-Path $OutputFolder "api-tokens.csv"
$rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] api-tokens.csv ({0} rows)" -f $rows.Count) -ForegroundColor Cyan

$hasExpiry = $rows | Where-Object { $_.ExpiresAt }
if ($hasExpiry) {
    $distinctExpiry = ($rows | Where-Object { $_.ExpiresAt } | Select-Object -ExpandProperty ExpiresAt -Unique)
    if (@($distinctExpiry).Count -eq 1) {
        Write-Host ("  [INFO] All tokens share the same ExpiresAt ({0}) - this reflects a shared/tenant-wide" -f $distinctExpiry) -ForegroundColor Gray
        Write-Host "         credential rotation deadline, not an individual per-token expiry." -ForegroundColor Gray
    }
}
$revokedCount = @($rows | Where-Object { $_.IsRevoked }).Count
if ($revokedCount -gt 0) { Write-Host ("  [INFO] {0} revoked token(s) still listed - IsRevoked=true" -f $revokedCount) -ForegroundColor Gray }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $outFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
