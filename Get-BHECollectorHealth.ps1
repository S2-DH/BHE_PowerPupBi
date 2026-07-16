# ===================================================================
# Get-BHECollectorHealth.ps1
# ===================================================================
# Lists BHE collectors (clients) with health + version, then pulls
# the tenant's available collector versions and flags out-of-date ones.
# Writes collector-health.csv for Power BI + raw JSON for inspection.
#
# Field names for /api/v2/clients vary by version, so this maps a set
# of likely names defensively. If a column is blank, check the raw
# JSON and adjust the candidate lists below.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { "C:\SDH_SO_LAB\_BHE-PowerBI\Data" }),
    [int]$StaleHours      = 4      # check-ins older than this = not Healthy
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Collector Health" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----- .env + auth plumbing (same as the extractor) ----------------

if (-not $EnvPath) {
    if ($PSScriptRoot) { $EnvPath = Join-Path $PSScriptRoot ".env" }
    else               { $EnvPath = Join-Path (Get-Location) ".env" }
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
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
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
    return Invoke-RestMethod -Uri $url -Method GET -Headers $hdr -TimeoutSec 30 -ErrorAction Stop
}

# Return the first present, non-empty property among candidate names
function Get-Prop {
    param($Obj, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne "") { return $p.Value }
    }
    return $null
}

$RawDir = Join-Path $OutputFolder "raw"
foreach ($d in @($OutputFolder, $RawDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$fileStamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$snapshotIso = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

# ===================================================================
# STEP 1: latest available collector versions (tenant-served)
# ===================================================================

Write-Host "STEP 1: Tenant collector versions" -ForegroundColor Yellow

function Get-LatestVersion {
    param($Data)
    if (-not $Data) { return $null }
    # explicit latest field?
    $explicit = Get-Prop $Data @('latest','recommended','latest_version')
    if ($explicit) { return "$explicit" }
    # otherwise look for a list of versions and take the highest semver
    $list = $null
    foreach ($n in @('versions','version_metadata','data')) {
        $p = $Data.PSObject.Properties[$n]
        if ($p -and $p.Value) { $list = $p.Value; break }
    }
    if (-not $list -and ($Data -is [System.Collections.IEnumerable])) { $list = $Data }
    if (-not $list) { return $null }

    $versions = foreach ($item in $list) {
        if ($item -is [string]) { $item }
        else { Get-Prop $item @('version','tag','name') }
    }
    $versions = $versions | Where-Object { $_ } | Sort-Object -Unique {
        $clean = ($_ -replace '^v', '') -replace '[^0-9.].*$', ''
        try { [version]$clean } catch { [version]'0.0' }
    }
    if ($versions) { return $versions[-1] }
    return $null
}

$latest = @{}
foreach ($ct in @('sharphound', 'azurehound')) {
    try {
        $resp = Invoke-BHERequest -Path "/api/v2/collectors/$ct"
        $resp | ConvertTo-Json -Depth 20 | Out-File (Join-Path $RawDir "collectors-$ct`_$fileStamp.json") -Encoding UTF8
        $data = if ($null -ne $resp.data) { $resp.data } else { $resp }
        $lv = Get-LatestVersion -Data $data
        $latest[$ct] = $lv
        Write-Host ("  [OK]  {0,-12} latest = {1}" -f $ct, $(if ($lv) { $lv } else { "(could not parse)" })) -ForegroundColor Green
    }
    catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "" }
        Write-Host ("  [SKIP] {0,-12} HTTP {1} - version compare will show 'Unknown'" -f $ct, $code) -ForegroundColor DarkYellow
    }
}

# OpenGraph extensions (BHE 9.0+) - versions for the OpenHound collectors.
# Build a platform-keyword -> version map (e.g. 'github' -> 'v1.2.4').
$extVersions = @{}
try {
    $resp = Invoke-BHERequest -Path "/api/v2/extensions"
    $resp | ConvertTo-Json -Depth 20 | Out-File (Join-Path $RawDir "extensions_$fileStamp.json") -Encoding UTF8
    $exts = if ($resp.data -and $resp.data.extensions) { $resp.data.extensions }
            elseif ($null -ne $resp.data)             { $resp.data }
            else                                      { $resp }
    foreach ($x in $exts) {
        $xName = "$(Get-Prop $x @('name','display_name')) $(Get-Prop $x @('namespace','key','schema'))".ToLower()
        $xVer  = Get-Prop $x @('version','schema_version')
        if ($xName -match 'github') { $extVersions['github'] = $xVer }
        if ($xName -match 'jamf')   { $extVersions['jamf']   = $xVer }
        if ($xName -match 'okta')   { $extVersions['okta']   = $xVer }
    }
    Write-Host ("  [..]  parsed {0} extension object(s)" -f @($exts).Count) -ForegroundColor DarkGray
    if ($extVersions.Count) {
        Write-Host ("  [OK]  extensions   {0}" -f (($extVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Green
    } else {
        Write-Host "  [OK]  extensions   (none matched github/jamf/okta)" -ForegroundColor DarkYellow
    }
}
catch {
    $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "" }
    Write-Host ("  [SKIP] extensions   HTTP {0} - OpenHound versions will be blank" -f $code) -ForegroundColor DarkYellow
}

# ===================================================================
# STEP 2: clients
# ===================================================================

Write-Host ""
Write-Host "STEP 2: Collectors (/api/v2/clients)" -ForegroundColor Yellow

try {
    $resp = Invoke-BHERequest -Path "/api/v2/clients"
    $resp | ConvertTo-Json -Depth 20 | Out-File (Join-Path $RawDir "clients_$fileStamp.json") -Encoding UTF8
    $clients = if ($null -ne $resp.data) { $resp.data } else { $resp }
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red; exit 1
}

function Compare-Version {
    param([string]$Installed, [string]$Latest)
    if (-not $Installed) { return "Unknown" }
    if (-not $Latest)    { return "Unknown" }
    $ci = ($Installed -replace '^v', '') -replace '[^0-9.].*$', ''
    $cl = ($Latest    -replace '^v', '') -replace '[^0-9.].*$', ''
    # pad both to 4 components so 2.13.0 and 2.13.0.0 compare equal
    $pi = @($ci.Split('.')); while ($pi.Count -lt 4) { $pi += '0' }
    $pl = @($cl.Split('.')); while ($pl.Count -lt 4) { $pl += '0' }
    try {
        $vi = [version](($pi[0..3]) -join '.')
        $vl = [version](($pl[0..3]) -join '.')
        if ($vi -eq $vl) { return "Up-to-date" }
        elseif ($vi -lt $vl) { return "Outdated" }
        else { return "Ahead" }
    } catch {
        if ($ci -eq $cl) { return "Up-to-date" } else { return "Check" }
    }
}

$rows = foreach ($c in $clients) {
    $name    = Get-Prop $c @('name','hostname','display_name')
    $clientHost = Get-Prop $c @('hostname','ip_address','address')
    $version = Get-Prop $c @('version','client_version','collector_version')
    $type    = Get-Prop $c @('type','client_type','collector_type')
    $user    = Get-Prop $c @('configured_user','current_user','user_principal_name','user_sid')
    $lastRaw = Get-Prop $c @('last_checkin','lastCheckin','last_check_in','updated_at','seen_at')
    $jobs    = Get-Prop $c @('completed_task_count','completed_job_count','completed_jobs')
    $current = Get-Prop $c @('current_task','current_job')

    # classify collector type
    $blob = "$type $name $clientHost $version".ToLower()
    if     ($blob -match 'azure')                                          { $ctKey = 'azurehound' }
    elseif ($blob -match 'sharphound|sharp_hound')                         { $ctKey = 'sharphound' }
    elseif ($blob -match '_oh_|openhound|opengraph|okta|jamf|github')      { $ctKey = 'openhound' }
    else                                                                   { $ctKey = 'sharphound' }

    $displayVersion = $version
    if ($ctKey -eq 'openhound') {
        # match the extension platform and use its version from /api/v2/extensions
        $platform = if ($blob -match 'github') { 'github' }
                    elseif ($blob -match 'jamf') { 'jamf' }
                    elseif ($blob -match 'okta') { 'okta' }
                    else { $null }
        $extVer = if ($platform) { $extVersions[$platform] } else { $null }
        if (-not $displayVersion) { $displayVersion = $extVer }   # clients had none; show extension version
        $latestForType = $extVer
        $verStatus     = if ($extVer) { "Installed" } else { "N/A (OpenGraph)" }
    } else {
        $latestForType = $latest[$ctKey]
        $verStatus     = Compare-Version -Installed $version -Latest $latestForType
    }

    # health from check-in age
    $age = $null; $health = "Unknown"
    if ($lastRaw) {
        try {
            $lastUtc = ([datetime]$lastRaw).ToUniversalTime()
            if ($lastUtc.Year -lt 2000) { $health = "Never checked in" }
            else {
                $age = [math]::Round((New-TimeSpan -Start $lastUtc -End ([datetime]::UtcNow)).TotalHours, 1)
                $health = if ($age -le $StaleHours) { "Healthy" }
                          elseif ($age -le ($StaleHours * 6)) { "Warning" }
                          else { "Stale" }
            }
        } catch { $health = "Unknown" }
    }

    [pscustomobject][ordered]@{
        SnapshotDate   = $snapshotIso
        Name           = $name
        Host           = $clientHost
        CollectorType  = $ctKey
        Version        = $displayVersion
        LatestVersion  = $latestForType
        VersionStatus  = $verStatus
        Health         = $health
        HoursSinceSeen = $age
        LastCheckin    = $lastRaw
        ConfiguredUser = $user
        CompletedJobs  = $jobs
        HasCurrentJob  = [bool]$current
    }
}

# ----- write CSV ---------------------------------------------------
$csv = Join-Path $OutputFolder "collector-health.csv"
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

# ----- console table ----------------------------------------------
Write-Host ""
$rows | Format-Table Name, CollectorType, Version, LatestVersion, VersionStatus, Health, HoursSinceSeen -AutoSize

# ----- summary -----------------------------------------------------
$total   = ($rows | Measure-Object).Count
$healthy = ($rows | Where-Object Health -eq "Healthy" | Measure-Object).Count
$stale   = ($rows | Where-Object { $_.Health -in @("Stale", "Never checked in") } | Measure-Object).Count
$outdated= ($rows | Where-Object VersionStatus -eq "Outdated" | Measure-Object).Count

Write-Host "========================================" -ForegroundColor Cyan
Write-Host (" Collectors : {0}" -f $total)            -ForegroundColor Gray
Write-Host (" Healthy    : {0}" -f $healthy)          -ForegroundColor Green
Write-Host (" Stale      : {0}" -f $stale)            -ForegroundColor $(if ($stale)    { "Red" } else { "Gray" })
Write-Host (" Outdated   : {0}" -f $outdated)         -ForegroundColor $(if ($outdated) { "Red" } else { "Gray" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $csv" -ForegroundColor Gray
Write-Host ""
