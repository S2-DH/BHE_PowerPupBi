# ===================================================================
# Get-BHEPanels.ps1  -  Data Quality + Finding Trends + Tier Zero comp
# ===================================================================
# Three new dashboard panels in one pass:
#   1. data-quality.csv     per-environment collection completeness
#   2. finding-trends.csv   new/resolved finding counts over time
#   3. tier-zero-comp.csv   Tier Zero membership broken down by kind
# Plus raw JSON for each. Reuses the .env + HMAC pattern.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { "C:\SDH_SO_LAB\_BHE-PowerBI\Data" })
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Panels: Quality / Trends / TierZero" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----- .env + auth plumbing ----------------------------------------

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
    return Invoke-RestMethod -Uri $url -Method GET -Headers $hdr -TimeoutSec 60 -ErrorAction Stop
}

function Get-Prop {
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
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

function Save-Raw { param($Obj, $Name) $Obj | ConvertTo-Json -Depth 20 | Out-File (Join-Path $RawDir "$($Name)_$fileStamp.json") -Encoding UTF8 }

# environments (drives all three panels)
Write-Host "Environments..." -ForegroundColor Yellow
$resp = Invoke-BHERequest -Path "/api/v2/available-domains"
$domains = if ($null -ne $resp.data) { $resp.data } else { $resp }
Write-Host ("  [OK]  {0} environment(s)" -f ($domains | Measure-Object).Count) -ForegroundColor Green

# ===================================================================
# 1. DATA QUALITY  (per-environment completeness)
# ===================================================================

Write-Host ""
Write-Host "1. Data quality" -ForegroundColor Yellow

$dqRows = New-Object System.Collections.ArrayList

foreach ($dom in $domains) {
    $domId   = Get-Prop $dom @('id')
    $domName = Get-Prop $dom @('name'); if (-not $domName) { $domName = $domId }
    $domType = Get-Prop $dom @('type')
    if (-not $domId) { continue }

    # AD vs Azure use different endpoints; try AD first, fall back to Azure
    $stat = $null
    foreach ($p in @("/api/v2/ad-domains/$domId/data-quality-stats",
                     "/api/v2/azure-tenants/$domId/data-quality-stats")) {
        try { $stat = Invoke-BHERequest -Path $p; break } catch { }
    }
    if (-not $stat) {
        Write-Host ("  [SKIP] {0,-22} no data-quality endpoint" -f $domName) -ForegroundColor DarkYellow
        continue
    }
    Save-Raw $stat "dataquality-$domId"

    # the stats payload is usually an array of daily samples; take the most recent
    $data = if ($null -ne $stat.data) { $stat.data } else { $stat }
    $latest = if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string]) { @($data)[-1] } else { $data }

    $sessComp = Get-Prop $latest @('session_completeness','SessionCompleteness')
    $lgComp   = Get-Prop $latest @('local_group_completeness','LocalGroupCompleteness')
    $users    = Get-Prop $latest @('users','Users')
    $computers= Get-Prop $latest @('computers','Computers')
    $groups   = Get-Prop $latest @('groups','Groups')
    $updated  = Get-Prop $latest @('updated_at','created_at')

    # completeness values are 0..1 ratios; convert to % where present
    $sessPct = if ($null -ne $sessComp) { [math]::Round([double]$sessComp * 100, 1) } else { $null }
    $lgPct   = if ($null -ne $lgComp)   { [math]::Round([double]$lgComp   * 100, 1) } else { $null }

    [void]$dqRows.Add([pscustomobject][ordered]@{
        SnapshotDate          = $snapshotIso
        Environment           = $domName
        EnvironmentId         = $domId
        Type                  = $domType
        SessionCompletenessPct= $sessPct
        LocalGroupCompletePct = $lgPct
        Users                 = $users
        Computers             = $computers
        Groups                = $groups
        LastCollected         = $updated
    })
    Write-Host ("  [OK]  {0,-22} session {1}%  lg {2}%" -f $domName, $sessPct, $lgPct) -ForegroundColor Green
}

$dqRows | Export-Csv -Path (Join-Path $OutputFolder "data-quality.csv") -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] data-quality.csv ({0} rows)" -f $dqRows.Count) -ForegroundColor Cyan

# ===================================================================
# 2. FINDING TRENDS  (new vs resolved over time, per environment)
# ===================================================================

Write-Host ""
Write-Host "2. Finding trends" -ForegroundColor Yellow

$trendRows = New-Object System.Collections.ArrayList

foreach ($dom in $domains) {
    $domId   = Get-Prop $dom @('id')
    $domName = Get-Prop $dom @('name'); if (-not $domName) { $domName = $domId }
    if (-not $domId) { continue }

    try {
        $tr = Invoke-BHERequest -Path "/api/v2/attack-paths/finding-trends?environments=$domId"
    } catch {
        try { $tr = Invoke-BHERequest -Path "/api/v2/posture-history/finding-trends?environments=$domId" }
        catch { Write-Host ("  [SKIP] {0,-22} no finding-trends" -f $domName) -ForegroundColor DarkYellow; continue }
    }
    Save-Raw $tr "findingtrends-$domId"
    $data = if ($null -ne $tr.data) { $tr.data } else { $tr }

    # finding-trends often returns { data: { findings:[...] } } or an array of {date,added,removed}
    $series = $null
    if ($data) {
        foreach ($n in @('findings','trends','data')) {
            $p = $data.PSObject.Properties[$n]; if ($p -and $p.Value) { $series = $p.Value; break }
        }
    }
    if (-not $series -and ($data -is [System.Collections.IEnumerable]) -and ($data -isnot [string])) { $series = $data }
    if (-not $series) { continue }

    foreach ($pt in $series) {
        [void]$trendRows.Add([pscustomobject][ordered]@{
            SnapshotDate  = $snapshotIso
            Environment   = $domName
            EnvironmentId = $domId
            Date          = Get-Prop $pt @('date','Date','created_at')
            New           = Get-Prop $pt @('added','new','New','finding_count_start')
            Resolved      = Get-Prop $pt @('removed','resolved','Resolved')
            Total         = Get-Prop $pt @('total','Total','finding_count')
        })
    }
    Write-Host ("  [OK]  {0,-22} {1} point(s)" -f $domName, ($series | Measure-Object).Count) -ForegroundColor Green
}

$trendRows | Export-Csv -Path (Join-Path $OutputFolder "finding-trends.csv") -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] finding-trends.csv ({0} rows)" -f $trendRows.Count) -ForegroundColor Cyan

# ===================================================================
# 3. TIER ZERO COMPOSITION  (members by kind)
# ===================================================================

Write-Host ""
Write-Host "3. Tier Zero composition" -ForegroundColor Yellow

$tzRows = New-Object System.Collections.ArrayList

# find the Tier Zero asset group tag
try {
    $tags = Invoke-BHERequest -Path "/api/v2/asset-group-tags"
    Save-Raw $tags "assetgrouptags"
    $tagList = if ($tags.data.tags) { $tags.data.tags } elseif ($tags.data) { $tags.data } else { $tags }
} catch {
    Write-Host "  [SKIP] asset-group-tags unavailable (older build may use /asset-groups)" -ForegroundColor DarkYellow
    $tagList = $null
}

if ($tagList) {
    foreach ($tag in $tagList) {
        $tagId   = Get-Prop $tag @('id')
        $tagName = Get-Prop $tag @('name','tag_name')
        if (-not $tagId) { continue }
        # only Tier Zero / High Value tags are interesting here
        if ($tagName -and $tagName -notmatch 'tier|zero|high|owned') { continue }

        # member count broken down by kind (Users/Computers/Groups/GPOs...)
        try {
            $mc = Invoke-BHERequest -Path "/api/v2/asset-group-tags/$tagId/members/counts"
        } catch {
            try { $mc = Invoke-BHERequest -Path "/api/v2/asset-group-tags/$tagId/member-counts" }
            catch { Write-Host ("  [SKIP] {0} member counts" -f $tagName) -ForegroundColor DarkYellow; continue }
        }
        Save-Raw $mc "tierzero-$tagId"
        $counts = if ($null -ne $mc.data) { $mc.data } else { $mc }

        # counts is usually { counts: { User: n, Computer: n, Group: n, ... } } or similar
        $byKind = $null
        if ($counts) {
            foreach ($n in @('counts','kinds','by_kind')) {
                $p = $counts.PSObject.Properties[$n]; if ($p -and $p.Value) { $byKind = $p.Value; break }
            }
        }
        if (-not $byKind) { $byKind = $counts }

        if ($byKind) {
            foreach ($prop in $byKind.PSObject.Properties) {
                if ($prop.Value -is [int] -or $prop.Value -is [long] -or $prop.Value -is [double]) {
                    [void]$tzRows.Add([pscustomobject][ordered]@{
                        SnapshotDate = $snapshotIso
                        Tag          = $tagName
                        Kind         = $prop.Name
                        Count        = $prop.Value
                    })
                }
            }
        }
        Write-Host ("  [OK]  {0}" -f $tagName) -ForegroundColor Green
    }
}

$tzRows | Export-Csv -Path (Join-Path $OutputFolder "tier-zero-comp.csv") -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] tier-zero-comp.csv ({0} rows)" -f $tzRows.Count) -ForegroundColor Cyan

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done. Check raw\ if any panel is empty -" -ForegroundColor Cyan
Write-Host " field names vary by build and I can remap." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
