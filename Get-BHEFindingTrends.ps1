# ===================================================================
# Get-BHEFindingTrends.ps1
# ===================================================================
# Pulls /api/v2/attack-paths/finding-trends - findings and their change
# between two dates, per finding type. This is the "is risk going up or
# down" endpoint - confirmed against SpecterOps' published OpenAPI spec
# (bloodhound.specterops.io/reference/attack-paths/list-finding-trends),
# not guessed from a field name.
#
# Different from finding-trends.csv produced by Get-BHEPanels.ps1 - that
# one predates this script and uses a different approach/endpoint. This
# writes to finding-movement.csv / finding-movement-summary.csv instead,
# deliberately not overwriting the existing file, so both can be compared
# before deciding whether this replaces the older one.
#
# Default window: last 30 days (matches the API's own default when
# -Start/-End aren't supplied). Default scope: Tier Zero + Hygiene tags
# combined (the API's default when asset_group_tag_id isn't supplied).
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder,
    [Nullable[int]]$Days = 30,        # lookback window in days - ignored if -Start is supplied
    [string]$Start,                   # RFC-3339 datetime - overrides -Days if supplied
    [string]$End,                     # RFC-3339 datetime - defaults to now
    [Nullable[int]]$AssetGroupTagId   # omit for API default (Tier Zero + Hygiene combined)
)

$ErrorActionPreference = "Stop"
if (-not $OutputFolder) {
    $OutputFolder = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { Join-Path (Get-Location) "Data" }
}
if (-not $EnvPath) {
    $EnvPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot ".env" } else { Join-Path (Get-Location) ".env" }
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
Write-Host " BHE Finding Trends (movement)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----- environments -----
Write-Host "Environments..." -ForegroundColor Yellow
try {
    $doms = Invoke-BHERequest -Path "/api/v2/available-domains"
    $domList = if ($doms.data) { $doms.data } else { $doms }
} catch {
    Write-Host ("  [FAIL] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
$envMap = @{}
foreach ($d in $domList) { $did = Get-Prop $d @('id'); $dn = Get-Prop $d @('name'); if ($did) { $envMap["$did"] = $dn } }
Write-Host ("  [OK]  {0} environment(s)" -f $envMap.Count) -ForegroundColor Green

if ($envMap.Count -eq 0) { Write-Host "  [FAIL] No environments to query." -ForegroundColor Red; exit 1 }

# ----- build query string -----
$qsParts = @()
foreach ($envId in $envMap.Keys) { $qsParts += "environments=$([System.Uri]::EscapeDataString($envId))" }
if ($Start) { $qsParts += "start=$([System.Uri]::EscapeDataString($Start))" }
elseif ($Days) { $qsParts += "start=$([System.Uri]::EscapeDataString(([DateTime]::UtcNow.AddDays(-$Days)).ToString('o')))" }
if ($End) { $qsParts += "end=$([System.Uri]::EscapeDataString($End))" }
if ($AssetGroupTagId) { $qsParts += "asset_group_tag_id=$AssetGroupTagId" }
$queryString = $qsParts -join "&"

Write-Host ""
Write-Host "Finding trends..." -ForegroundColor Yellow
try {
    $resp = Invoke-BHERequest -Path "/api/v2/attack-paths/finding-trends?$queryString"
} catch {
    Write-Host ("  [FAIL] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$resp | ConvertTo-Json -Depth 12 | Out-File (Join-Path $RawDir "finding-trends-movement_$fileStamp.json") -Encoding UTF8

$windowStart = Get-Prop $resp @('start')
$windowEnd   = Get-Prop $resp @('end')
$findings    = $resp.data.findings
$totalStart  = Get-Prop $resp.data @('total_finding_count_start')
$totalEnd    = Get-Prop $resp.data @('total_finding_count_end')

if (-not $findings -or $findings.Count -eq 0) {
    Write-Host "  [WARN] No finding trend rows returned - check raw\finding-trends-movement_$fileStamp.json" -ForegroundColor DarkYellow
    Write-Host "         (an empty result here is valid if nothing changed in the window)" -ForegroundColor Gray
}

$rows = New-Object System.Collections.ArrayList
foreach ($f in $findings) {
    $envIds = $f.environment_ids
    $envNames = ($envIds | ForEach-Object { if ($envMap.ContainsKey("$_")) { $envMap["$_"] } else { $_ } }) -join "; "

    $startCount = Get-Prop $f @('finding_count_start')
    $endCount   = Get-Prop $f @('finding_count_end')
    $netChange  = $null
    if ($null -ne $startCount -and $null -ne $endCount) { $netChange = $endCount - $startCount }

    [void]$rows.Add([pscustomobject][ordered]@{
        SnapshotDate        = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        WindowStart         = $windowStart
        WindowEnd           = $windowEnd
        Environments        = $envNames
        Finding             = Get-Prop $f @('finding')
        DisplayTitle        = Get-Prop $f @('display_title')
        DisplayType         = Get-Prop $f @('display_type')
        CompositeRisk       = Get-Prop $f @('composite_risk')
        FindingCountStart   = $startCount
        FindingCountEnd     = $endCount
        NetChange           = $netChange
        FindingCountIncrease= Get-Prop $f @('finding_count_increase')
        FindingCountDecrease= Get-Prop $f @('finding_count_decrease')
        ImpactCount         = Get-Prop $f @('impact_count')
        ExposureCount       = Get-Prop $f @('exposure_count')
        ArchivedCount       = Get-Prop $f @('archived_count')
    })
}

$outFile = Join-Path $OutputFolder "finding-movement.csv"
$rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] finding-movement.csv ({0} rows)" -f $rows.Count) -ForegroundColor Cyan

# ----- overall summary row -----
$summaryRow = [pscustomobject][ordered]@{
    SnapshotDate            = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    WindowStart             = $windowStart
    WindowEnd               = $windowEnd
    TotalFindingCountStart  = $totalStart
    TotalFindingCountEnd    = $totalEnd
    NetChange               = if ($null -ne $totalStart -and $null -ne $totalEnd) { $totalEnd - $totalStart } else { $null }
}
$summaryFile = Join-Path $OutputFolder "finding-movement-summary.csv"
@($summaryRow) | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8
Write-Host "  [FILE] finding-movement-summary.csv" -ForegroundColor Cyan

if ($rows.Count -gt 0) {
    Write-Host ""
    Write-Host "Top movers (by net change):" -ForegroundColor Yellow
    $rows | Sort-Object { [math]::Abs([int]($_.NetChange | ForEach-Object { if ($_) { $_ } else { 0 } })) } -Descending |
        Select-Object -First 5 DisplayTitle, FindingCountStart, FindingCountEnd, NetChange |
        Format-Table -AutoSize | Out-String | Write-Host
}

Write-Host ("  Total findings: {0} -> {1}" -f $totalStart, $totalEnd) -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $outFile" -ForegroundColor Gray
Write-Host "  CSV: $summaryFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
