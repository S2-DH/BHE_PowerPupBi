# ===================================================================
# Get-BHECertificationSelectors.ps1
# ===================================================================
# Enriches certifications.csv with the selector/rule (and source type)
# that placed each object into its asset group tag.
#
# For every row in certifications.csv, calls:
#   GET /api/v2/asset-group-tags/{AssetGroupTagId}/members/{Id}
#
# and pulls out whatever "why is this object in this tag" info comes
# back - selector name/id, source (Selector / Seed / Parent / etc.).
#
# NOTE ON FIELD NAMES: the exact shape of this endpoint's response
# wasn't confirmed against a live tenant while building this - the
# first run below dumps the raw JSON for row 1 to raw/ so you can see
# the actual field names before trusting the parsed CSV. If the
# $selInfo extraction below comes back blank/"Unknown" for everything,
# open that raw JSON, find the real field name, and adjust the
# Get-Prop candidate list a few lines down.
#
# Requires certifications.csv (from Get-BHECertifications.ps1) INCLUDING
# an "Id" column - the numeric member id (e.g. 21572), not ObjectId.
# If your certifications.csv doesn't have that column yet, add it to
# the row-building loop in Get-BHECertifications.ps1:
#
#   Id = Get-Prop $m @('id')
#
# alongside the existing Name/PrimaryKind/Environment/etc. fields, then
# re-run that script before running this one.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$InputCsv = ".\certifications.csv",
    [string]$OutputFolder = ".",
    [int]$ThrottleMs = 50,          # small delay between calls so we don't hammer the API across 200+ rows
    [switch]$TestFirstRowOnly       # sanity-check one row before committing to the full run
)

$ErrorActionPreference = "Stop"

# ----- .env loading, HMAC signing, Invoke-BHERequest, Get-Prop -----
# (same conventions as Get-BHECertifications.ps1, duplicated here so
#  this script can run standalone without dot-sourcing anything)

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
if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory -Path $RawDir | Out-Null }
$fileStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

if (-not (Test-Path $InputCsv)) {
    Write-Host "  [FAIL] Can't find $InputCsv - run Get-BHECertifications.ps1 first." -ForegroundColor Red
    exit 1
}

$certs = Import-Csv -Path $InputCsv

if (-not ($certs | Get-Member -Name "Id" -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] certifications.csv has no 'Id' column." -ForegroundColor Red
    Write-Host "  Add 'Id = Get-Prop `$m @(''id'')' to the row builder in Get-BHECertifications.ps1 and re-run it." -ForegroundColor Yellow
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  BHE Certification Selector Enrichment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Rows to process: {0}" -f $certs.Count) -ForegroundColor Gray
Write-Host ""

$enriched = New-Object System.Collections.ArrayList
$rowNum = 0
$firstDumpWritten = $false

foreach ($row in $certs) {
    $rowNum++
    $pct = [math]::Round(($rowNum / $certs.Count) * 100)
    Write-Progress -Activity "Fetching selector info" -Status "$rowNum / $($certs.Count) - $($row.Name)" -PercentComplete $pct

    $selectorNames  = ""
    $selectorIds    = ""
    $selectorCount  = 0
    $anyAutoCertify = $false
    $anyDefault     = $false
    $matchType      = "Unknown"

    try {
        $resp = Invoke-BHERequest -Path "/api/v2/asset-group-tags/$($row.AssetGroupTagId)/members/$($row.Id)"

        # Dump the very first response so you can confirm real field names
        if (-not $firstDumpWritten) {
            $resp | ConvertTo-Json -Depth 12 | Out-File (Join-Path $RawDir "member-detail-sample_$fileStamp.json") -Encoding UTF8
            $firstDumpWritten = $true
            Write-Host "  [INFO] Sample response saved - check raw\member-detail-sample_$fileStamp.json if fields look wrong" -ForegroundColor DarkCyan
        }

        # Real shape: data.member.selectors is an array - an object can match 0, 1, or several selectors
        $memberData = $resp.data.member
        $selectors  = $memberData.selectors

        if ($selectors -and $selectors.Count -gt 0) {
            $selectorCount  = $selectors.Count
            $selectorNames  = ($selectors | ForEach-Object { $_.name }) -join "; "
            $selectorIds    = ($selectors | ForEach-Object { $_.id }) -join "; "
            $anyAutoCertify = [bool]($selectors | Where-Object { $_.auto_certify -eq 1 -or $_.auto_certify -eq $true })
            $anyDefault     = [bool]($selectors | Where-Object { $_.is_default -eq $true })
            $matchType      = if ($anyDefault) { "Default Selector" } elseif ($anyAutoCertify) { "Auto-Certify Selector" } else { "Manual Selector" }
        } else {
            $matchType = "No Selector (manual add / seed)"
        }

    } catch {
        Write-Host ("  [WARN] {0}: {1}" -f $row.Name, $_.Exception.Message) -ForegroundColor DarkYellow
        $matchType = "Error"
    }

    [void]$enriched.Add([pscustomobject][ordered]@{
        Id             = $row.Id
        Name           = $row.Name
        PrimaryKind    = $row.PrimaryKind
        Environment    = $row.Environment
        Tag            = $row.Tag
        AssetGroupTagId= $row.AssetGroupTagId
        CertifiedLabel = $row.CertifiedLabel
        CertifiedBy    = $row.CertifiedBy
        CreatedAt      = $row.CreatedAt
        SelectorNames  = $selectorNames
        SelectorIds    = $selectorIds
        SelectorCount  = $selectorCount
        AnyAutoCertify = $anyAutoCertify
        MatchType      = $matchType
    })

    if ($TestFirstRowOnly) {
        Write-Host ""
        Write-Host "  --- TestFirstRowOnly: stopping after row 1 ---" -ForegroundColor Yellow
        Write-Host ("  SelectorNames: {0}" -f $selectorNames)
        Write-Host ("  SelectorCount: {0}" -f $selectorCount)
        Write-Host ("  MatchType:     {0}" -f $matchType)
        Write-Host ("  Raw JSON:      raw\member-detail-sample_$fileStamp.json") -ForegroundColor Gray
        exit 0
    }

    if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
}

Write-Progress -Activity "Fetching selector info" -Completed

$outFile = Join-Path $OutputFolder "certifications-with-selectors.csv"
$enriched | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("  [FILE] certifications-with-selectors.csv ({0} rows)" -f $enriched.Count) -ForegroundColor Cyan

if ($enriched.Count -gt 0) {
    Write-Host ""
    Write-Host "By match type:" -ForegroundColor Yellow
    $enriched | Group-Object MatchType | Sort-Object Count -Descending |
        Select-Object @{n='MatchType';e={$_.Name}}, Count | Format-Table -AutoSize
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $outFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
