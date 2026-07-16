# ===================================================================
# Get-BHECertifications.ps1
# ===================================================================
# Pulls /api/v2/asset-group-tags/certifications - the attestation
# status of privilege-zone (Tier Zero etc.) members.
#
# certified codes:  0 = Pending  1 = Revoked  2 = Manual  3 = Auto
#
# Output: certifications.csv  (one row per member)
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder,
    [int]$PageSize = 100
)

$ErrorActionPreference = "Stop"
if (-not $OutputFolder) {
    $OutputFolder = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { Join-Path (Get-Location) "Data" }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Certifications (privilege zones)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

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
$fileStamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$snapshotIso = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

# ----- build id -> name lookups (tags + environments) --------------
Write-Host "Lookups..." -ForegroundColor Yellow
$tagMap = @{}
try {
    $tags = Invoke-BHERequest -Path "/api/v2/asset-group-tags"
    $tagList = if ($tags.data.tags) { $tags.data.tags } elseif ($tags.data) { $tags.data } else { $tags }
    foreach ($t in $tagList) { $tid = Get-Prop $t @('id'); $tn = Get-Prop $t @('name'); if ($null -ne $tid) { $tagMap["$tid"] = $tn } }
    Write-Host ("  [OK]  {0} tag(s)" -f $tagMap.Count) -ForegroundColor Green
} catch { Write-Host "  [WARN] tag lookup failed - will show numeric IDs" -ForegroundColor DarkYellow }

$envMap = @{}
try {
    $doms = Invoke-BHERequest -Path "/api/v2/available-domains"
    $domList = if ($doms.data) { $doms.data } else { $doms }
    foreach ($d in $domList) { $did = Get-Prop $d @('id'); $dn = Get-Prop $d @('name'); if ($did) { $envMap["$did"] = $dn } }
    Write-Host ("  [OK]  {0} environment(s)" -f $envMap.Count) -ForegroundColor Green
} catch { Write-Host "  [WARN] env lookup failed - will show raw IDs" -ForegroundColor DarkYellow }

# ----- certification code -> label ---------------------------------
$certLabels = @{ "0" = "Pending"; "1" = "Revoked"; "2" = "Manual"; "3" = "Auto" }

# ----- paginate certifications -------------------------------------
Write-Host ""
Write-Host "Certifications..." -ForegroundColor Yellow

$rows = New-Object System.Collections.ArrayList
$skip = 0; $total = $null

do {
    try {
        $resp = Invoke-BHERequest -Path "/api/v2/asset-group-tags/certifications?skip=$skip&limit=$PageSize"
    } catch {
        Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        if ($skip -eq 0) { exit 1 } else { break }
    }

    if ($skip -eq 0) {
        $resp | ConvertTo-Json -Depth 12 | Out-File (Join-Path $RawDir "certifications_$fileStamp.json") -Encoding UTF8
        $total = $resp.count
        Write-Host ("  total: {0}" -f $total) -ForegroundColor Gray
    }

    $members = $null
    if ($resp.data -and $resp.data.members) { $members = $resp.data.members }
    elseif ($resp.data) { $members = $resp.data }
    if (-not $members -or ($members | Measure-Object).Count -eq 0) { break }

    foreach ($m in $members) {
        $certInt = Get-Prop $m @('certified')
        $tagId   = Get-Prop $m @('asset_group_tag_id')
        $envId   = Get-Prop $m @('environment_id')
        [void]$rows.Add([pscustomobject][ordered]@{
            SnapshotDate   = $snapshotIso
            Id             = Get-Prop $m @('id')
            Name           = Get-Prop $m @('name')
            PrimaryKind    = Get-Prop $m @('primary_kind')
            Environment    = if ($envId -and $envMap.ContainsKey("$envId")) { $envMap["$envId"] } else { $envId }
            Tag            = if ($null -ne $tagId -and $tagMap.ContainsKey("$tagId")) { $tagMap["$tagId"] } else { $tagId }
            AssetGroupTagId= $tagId
            Certified      = $certInt
            CertifiedLabel = if ($null -ne $certInt -and $certLabels.ContainsKey("$certInt")) { $certLabels["$certInt"] } else { "Unknown" }
            CertifiedBy    = Get-Prop $m @('certified_by')
            CreatedAt      = Get-Prop $m @('created_at')
            ObjectId       = Get-Prop $m @('object_id')
        })
    }

    $skip += $PageSize
    $got = ($members | Measure-Object).Count
} while ($total -ne $null -and $skip -lt $total -and $got -gt 0)

# ----- write -------------------------------------------------------
$outFile = Join-Path $OutputFolder "certifications.csv"
$rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ("  [FILE] certifications.csv ({0} rows)" -f $rows.Count) -ForegroundColor Cyan

# ----- console summary ---------------------------------------------
if ($rows.Count -gt 0) {
    Write-Host ""
    Write-Host "By certification status:" -ForegroundColor Yellow
    $rows | Group-Object CertifiedLabel | Sort-Object Count -Descending |
        Select-Object @{n='Status';e={$_.Name}}, Count | Format-Table -AutoSize

    Write-Host "By tag:" -ForegroundColor Yellow
    $rows | Group-Object Tag | Sort-Object Count -Descending |
        Select-Object @{n='Tag';e={$_.Name}}, Count | Format-Table -AutoSize
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $outFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
