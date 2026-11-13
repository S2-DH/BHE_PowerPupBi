# ===================================================================
# Invoke-BHEExtract.ps1  -  BHE -> CSV/JSON extractor for Power BI
# ===================================================================
# Reuses the .env loader + 3-step HMAC from the auth test.
# For each endpoint it writes:
#   - a flattened CSV into  <OutputFolder>\         (for Power BI)
#   - the raw JSON into      <OutputFolder>\raw\     (for inspection)
# Every endpoint is isolated in try/catch so one failure won't stop
# the run - handy while you're discovering what your tenant exposes.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder
)

$ErrorActionPreference = "Stop"
if (-not $OutputFolder) {
    $OutputFolder = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { Join-Path (Get-Location) "Data" }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Extract -> Power BI (local)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ===================================================================
# .ENV LOADING (same parser as the auth test)
# ===================================================================

if (-not $EnvPath) {
    if ($PSScriptRoot) { $EnvPath = Join-Path $PSScriptRoot ".env" }
    else               { $EnvPath = Join-Path (Get-Location) ".env" }
}

function Import-DotEnv {
    param([string]$Path)
    $envVars = @{}
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        if ($trimmed.StartsWith("export ")) { $trimmed = $trimmed.Substring(7).Trim() }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim()
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $envVars[$key] = $val
    }
    return $envVars
}

if (-not (Test-Path $EnvPath)) {
    Write-Host "[FAIL] .env not found at: $EnvPath" -ForegroundColor Red
    exit 1
}

$envData      = Import-DotEnv -Path $EnvPath
$restEndpoint = $envData["BHE_API_URL"]
$tokenId      = $envData["BHE_TOKEN_ID"]
$tokenKey     = $envData["BHE_TOKEN_KEY"]

if ([string]::IsNullOrWhiteSpace($restEndpoint) -or
    [string]::IsNullOrWhiteSpace($tokenId) -or
    [string]::IsNullOrWhiteSpace($tokenKey)) {
    Write-Host "[FAIL] .env must contain BHE_API_URL, BHE_TOKEN_ID, BHE_TOKEN_KEY" -ForegroundColor Red
    exit 1
}

if (-not $restEndpoint.StartsWith("http://") -and -not $restEndpoint.StartsWith("https://")) {
    $restEndpoint = "https://$restEndpoint"
}
$restEndpoint = $restEndpoint.TrimEnd('/')

Write-Host "[INFO] Endpoint    : $restEndpoint" -ForegroundColor Gray
Write-Host "[INFO] Output      : $OutputFolder" -ForegroundColor Gray

# ===================================================================
# OUTPUT FOLDERS + TIMESTAMPS
# ===================================================================

$RawDir = Join-Path $OutputFolder "raw"
foreach ($d in @($OutputFolder, $RawDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$snapshotIso  = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")  # row stamp
$dateStamp    = Get-Date -Format "yyyy-MM-dd"                         # daily file
$fileStamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"                  # raw json

# ===================================================================
# HMAC SIGNATURE (unchanged - 3-step chained HMAC-SHA256)
# ===================================================================

function Get-BHEHMACSignature {
    param([string]$TokenId, [string]$TokenKey, [string]$Method, [string]$Uri)
    $uriObj   = [System.Uri]$Uri
    $endpoint = $uriObj.PathAndQuery
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss+00:00")
    $dateKey   = $timestamp.Substring(0, 13)

    $h1 = New-Object System.Security.Cryptography.HMACSHA256
    $h1.Key = [System.Text.Encoding]::UTF8.GetBytes($TokenKey)
    $hash1 = $h1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Method$endpoint"))

    $h2 = New-Object System.Security.Cryptography.HMACSHA256
    $h2.Key = $hash1
    $hash2 = $h2.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dateKey))

    $h3 = New-Object System.Security.Cryptography.HMACSHA256
    $h3.Key = $hash2
    $hash3 = $h3.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(""))

    return @{
        "Authorization" = "bhesignature $TokenId"
        "RequestDate"   = $timestamp
        "Signature"     = [System.Convert]::ToBase64String($hash3)
        "Content-Type"  = "application/json"
    }
}

# ===================================================================
# CORE REQUEST WRAPPER
# ===================================================================
# $Path is everything after the host, e.g. "/api/v2/available-domains"
# Returns the parsed response object (or throws).

function Invoke-BHERequest {
    param([string]$Path)
    $url     = "$restEndpoint$Path"
    $headers = Get-BHEHMACSignature -TokenId $tokenId -TokenKey $tokenKey -Method "GET" -Uri $url
    return Invoke-RestMethod -Uri $url -Method GET -Headers $headers -TimeoutSec 30 -ErrorAction Stop
}

# ===================================================================
# FLATTENER
# ===================================================================
# Turns nested objects/arrays into compact-JSON strings so the row
# stays CSV-friendly, and stamps on any extra columns (Environment etc).

function ConvertTo-FlatRows {
    param($Rows, [hashtable]$Extra = @{})

    if ($null -eq $Rows) { return @() }
    if ($Rows -isnot [System.Collections.IEnumerable] -or $Rows -is [string]) { $Rows = @($Rows) }

    $out = foreach ($r in $Rows) {
        $h = [ordered]@{}
        foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
        $h["SnapshotDate"] = $snapshotIso
        if ($r -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $r.PSObject.Properties) {
                $v = $p.Value
                if ($v -is [System.Management.Automation.PSCustomObject] -or
                    ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])) {
                    $h[$p.Name] = ($v | ConvertTo-Json -Compress -Depth 12)
                } else {
                    $h[$p.Name] = $v
                }
            }
        } else {
            $h["Value"] = $r
        }
        [pscustomobject]$h
    }
    return $out
}

# ===================================================================
# GENERIC ENDPOINT EXPORTER
# ===================================================================

function Export-BHEEndpoint {
    param(
        [string]$Name,                 # base filename
        [string]$Path,                 # API path
        [switch]$Dated,                # append _yyyy-MM-dd to the csv name
        [hashtable]$ExtraColumns = @{}
    )

    try {
        $resp = Invoke-BHERequest -Path $Path

        # raw json (always)
        $rawFile = Join-Path $RawDir "$($Name)_$fileStamp.json"
        $resp | ConvertTo-Json -Depth 20 | Out-File -FilePath $rawFile -Encoding UTF8

        # data payload (BHE wraps results in .data)
        $data = if ($null -ne $resp.data) { $resp.data } else { $resp }
        $rows = ConvertTo-FlatRows -Rows $data -Extra $ExtraColumns

        $csvName = if ($Dated) { "$($Name)_$dateStamp.csv" } else { "$($Name).csv" }
        $csvFile = Join-Path $OutputFolder $csvName
        $rowCount = ($rows | Measure-Object).Count

        if ($rowCount -gt 0) {
            $rows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        } else {
            # still drop an empty marker so you can see it returned nothing
            "" | Out-File -FilePath $csvFile -Encoding UTF8
        }

        # truncation hint: compare reported count to rows returned
        $note = ""
        if ($null -ne $resp.count -and $resp.count -gt $rowCount) {
            $note = "  [WARN] API reports $($resp.count) total but $rowCount returned - may be paged"
        }

        Write-Host ("  [OK]  {0,-32} {1,5} rows -> {2}{3}" -f $Name, $rowCount, $csvName, $note) -ForegroundColor Green
        return $data
    }
    catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "" }
        Write-Host ("  [SKIP] {0,-32} HTTP {1}  ({2})" -f $Name, $code, $_.Exception.Message) -ForegroundColor DarkYellow
        return $null
    }
}

# ===================================================================
# RUN
# ===================================================================

Write-Host ""
Write-Host "STEP 1: Auth check (/api/v2/self)" -ForegroundColor Yellow
try {
    $self = Invoke-BHERequest -Path "/api/v2/self"
    $who  = if ($self.data.email_address) { $self.data.email_address } else { "(unknown)" }
    Write-Host "  [PASS] Authenticated as $who" -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Auth failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "STEP 2: Core endpoints" -ForegroundColor Yellow

# Lookup / current-state tables (overwrite latest)
$domains = Export-BHEEndpoint -Name "available-domains" -Path "/api/v2/available-domains"
Export-BHEEndpoint -Name "clients"        -Path "/api/v2/clients"            | Out-Null
Export-BHEEndpoint -Name "posture-stats"  -Path "/api/v2/posture-stats"         | Out-Null

# Best-effort extras (paths vary by version - SKIP is fine if absent)
Export-BHEEndpoint -Name "completeness"   -Path "/api/v2/completeness"       | Out-Null
Export-BHEEndpoint -Name "audit"          -Path "/api/v2/audit?limit=1000"   | Out-Null

# ===================================================================
# STEP 3: Per-environment posture history
# ===================================================================

Write-Host ""
Write-Host "STEP 3: Posture history (per environment)" -ForegroundColor Yellow

$historyMetrics = @("exposure", "findings", "attack-paths")
$historyBuckets = @{}
foreach ($m in $historyMetrics) { $historyBuckets[$m] = New-Object System.Collections.ArrayList }

if ($domains) {
    foreach ($env in $domains) {
        $envId   = $env.id
        $envName = if ($env.name) { $env.name } else { $envId }
        if (-not $envId) { continue }

        foreach ($metric in $historyMetrics) {
            try {
                $resp = Invoke-BHERequest -Path "/api/v2/posture-history/$metric`?environments=$envId"
                $data = if ($null -ne $resp.data) { $resp.data } else { $resp }
                $rows = ConvertTo-FlatRows -Rows $data -Extra @{
                    Environment   = $envName
                    EnvironmentId = $envId
                    Metric        = $metric
                }
                [void]$historyBuckets[$metric].AddRange(@($rows))
                Write-Host ("  [OK]  {0,-20} {1,-14} {2,4} points" -f $envName, $metric, ($rows | Measure-Object).Count) -ForegroundColor Green
            }
            catch {
                Write-Host ("  [SKIP] {0,-20} {1,-14} {2}" -f $envName, $metric, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
    }

    # one combined CSV per metric, all environments stacked
    foreach ($metric in $historyMetrics) {
        $rows = $historyBuckets[$metric]
        $csv  = Join-Path $OutputFolder "posture-history-$metric.csv"
        if ($rows.Count -gt 0) {
            $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
            Write-Host ("  [FILE] posture-history-{0}.csv  ({1} rows)" -f $metric, $rows.Count) -ForegroundColor Cyan
        }
    }
}
else {
    Write-Host "  [SKIP] No environments returned - cannot pull history" -ForegroundColor DarkYellow
}

# ===================================================================
# DONE
# ===================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Extract complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSVs : $OutputFolder" -ForegroundColor Gray
Write-Host "  Raw  : $RawDir" -ForegroundColor Gray
Write-Host ""
Write-Host "  In Power BI: Get Data -> Folder -> $OutputFolder" -ForegroundColor Yellow
Write-Host ""
