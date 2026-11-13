# ===================================================================
# Get-BHEFindings.ps1
# ===================================================================
# Replicates the Splunk SOAR / Cortex XSOAR method: poll attack-path
# findings via /api/v2/domains/{id}/details, environment by environment.
#
# Flow:
#   1. available-domains            -> environments
#   2. /domains/{id}/available-types -> finding types present per env
#   3. /domains/{id}/details?finding={type}&limit=1 -> pagination 'count'
#      gives the number of findings of that type (the card number)
#
# Outputs:
#   finding-summary.csv  -> Environment, FindingType, Count, Severity   (cards/table)
#   finding-details.csv  -> per-principal rows (only if -DetailLimit > 0) (SOAR-style pane)
#   raw\ JSON for inspection
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder = "C:\SDH_SO_LAB\_BHE-PowerBI\Data",
    [int]$DetailLimit     = 0   # 0 = summary only; e.g. 500 = also pull up to 500 rows per type
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Findings (SOAR-style poll)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----- .env + auth plumbing (same as the other scripts) ------------

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
# STEP 1: environments
# ===================================================================

Write-Host "STEP 1: Environments" -ForegroundColor Yellow
try {
    $resp = Invoke-BHERequest -Path "/api/v2/available-domains"
    $domains = if ($null -ne $resp.data) { $resp.data } else { $resp }
    Write-Host ("  [OK]  {0} environment(s)" -f ($domains | Measure-Object).Count) -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red; exit 1
}

# ===================================================================
# STEP 2: finding types + counts per environment
# ===================================================================

Write-Host ""
Write-Host "STEP 2: Finding types per environment" -ForegroundColor Yellow

$summaryRows = New-Object System.Collections.ArrayList
$detailRows  = New-Object System.Collections.ArrayList

foreach ($dom in $domains) {
    $domId   = Get-Prop $dom @('id')
    $domName = Get-Prop $dom @('name')
    if (-not $domId) { continue }
    if (-not $domName) { $domName = $domId }

    # available finding types for this environment
    try {
        $typesResp = Invoke-BHERequest -Path "/api/v2/domains/$domId/available-types"
        $types = if ($null -ne $typesResp.data) { $typesResp.data } else { $typesResp }
    }
    catch {
        Write-Host ("  [SKIP] {0,-22} available-types HTTP error" -f $domName) -ForegroundColor DarkYellow
        continue
    }

    if (-not $types -or ($types | Measure-Object).Count -eq 0) {
        Write-Host ("  [--]  {0,-22} no finding types" -f $domName) -ForegroundColor DarkGray
        continue
    }

    Write-Host ("  {0} ({1} type(s))" -f $domName, ($types | Measure-Object).Count) -ForegroundColor White

    foreach ($t in $types) {
        # a type may be a plain string or an object
        $findingType = if ($t -is [string]) { $t } else { Get-Prop $t @('finding', 'type', 'id', 'name') }
        if (-not $findingType) { continue }

        $enc = [System.Uri]::EscapeDataString($findingType)

        # limit=1 -> the pagination 'count' is the number of findings of this type
        try {
            $det = Invoke-BHERequest -Path "/api/v2/domains/$domId/details?finding=$enc&skip=0&limit=1"
        }
        catch {
            Write-Host ("     [skip] {0} (details error)" -f $findingType) -ForegroundColor DarkYellow
            continue
        }

        $count = if ($null -ne $det.count) { $det.count } else { ($det.data | Measure-Object).Count }

        # grab severity from the first row if present (butterfly analysis on)
        $sev = ""
        if ($det.data -and $det.data.Count -ge 1) {
            $sev = Get-Prop $det.data[0] @('Severity', 'severity')
        }

        [void]$summaryRows.Add([pscustomobject][ordered]@{
            SnapshotDate  = $snapshotIso
            Environment   = $domName
            EnvironmentId = $domId
            FindingType   = $findingType
            Count         = $count
            Severity      = $sev
        })

        Write-Host ("     {0,-45} {1,8}" -f $findingType, $count) -ForegroundColor Gray

        # optional: pull capped detail rows for the SOAR-style pane
        if ($DetailLimit -gt 0 -and $count -gt 0) {
            $pulled = 0; $skip = 0; $page = [Math]::Min(1000, $DetailLimit)
            while ($pulled -lt $DetailLimit) {
                try {
                    $dd = Invoke-BHERequest -Path "/api/v2/domains/$domId/details?finding=$enc&skip=$skip&limit=$page"
                } catch { break }
                $rows = $dd.data
                if (-not $rows -or $rows.Count -eq 0) { break }
                foreach ($r in $rows) {
                    $principalVal   = Get-Prop $r @('Principal', 'from_principal_name', 'PrincipalName')
                    $toPrincipalVal = Get-Prop $r @('ToPrincipal', 'to_principal_name')

                    # Coalesce the "who/what this row is about". Relationship/ACL
                    # findings (T0GenericAll, T0MemberOf, ...) leave Principal empty
                    # and carry the Tier Zero TARGET in ToPrincipal; list findings
                    # (ASREPRoasting, Kerberoasting, ...) carry the exposed source
                    # principal in Principal. AffectedRole records which of the two
                    # this row actually is, so the table is self-documenting.
                    if ([string]::IsNullOrWhiteSpace($principalVal)) {
                        $affectedPrincipal = $toPrincipalVal
                        $affectedRole      = 'Tier Zero Target'
                    }
                    else {
                        $affectedPrincipal = $principalVal
                        $affectedRole      = 'Exposed Principal'
                    }

                    [void]$detailRows.Add([pscustomobject][ordered]@{
                        SnapshotDate      = $snapshotIso
                        Environment       = $domName
                        EnvironmentId     = $domId
                        FindingType       = $findingType
                        AffectedPrincipal = $affectedPrincipal
                        AffectedRole      = $affectedRole
                        Principal         = $principalVal
                        PrincipalKind     = Get-Prop $r @('PrincipalKind', 'from_principal_kind')
                        ToPrincipal       = $toPrincipalVal
                        Severity          = Get-Prop $r @('Severity')
                        ImpactCount       = Get-Prop $r @('ImpactCount')
                        ExposureCount     = Get-Prop $r @('ExposureCount')
                        Accepted          = Get-Prop $r @('Accepted')
                        FirstSeen         = Get-Prop $r @('created_at')
                    })
                    $pulled++
                    if ($pulled -ge $DetailLimit) { break }
                }
                $skip += $page
                if ($rows.Count -lt $page) { break }
            }
        }
    }
}

# ===================================================================
# DEDUPE detail rows
# ===================================================================
# The /details endpoint returns one row per attack PATH, so a single
# principal that reaches N Tier Zero targets appears N times. For the
# SOAR-style table we want one row per unique finding-against-principal
# (matching BHE's distinct-principal Exposure Count concept).
#
# Key = Environment + FindingType + AffectedPrincipal (the coalesced
# Principal/ToPrincipal value computed above). We keep the EARLIEST
# FirstSeen per group so the "how long has this been open" signal
# survives.

if ($DetailLimit -gt 0 -and $detailRows.Count -gt 0) {
    $beforeCount = $detailRows.Count
    $detailRows = @(
        $detailRows |
            Group-Object Environment, FindingType, AffectedPrincipal |
            ForEach-Object {
                $_.Group |
                    Sort-Object { try { [datetime]$_.FirstSeen } catch { [datetime]::MaxValue } } |
                    Select-Object -First 1
            }
    )
    Write-Host ("  [DEDUPE] detail rows {0} -> {1}" -f $beforeCount, $detailRows.Count) -ForegroundColor Cyan
}

# ===================================================================
# WRITE
# ===================================================================

Write-Host ""
$sumFile = Join-Path $OutputFolder "finding-summary.csv"
$summaryRows | Export-Csv -Path $sumFile -NoTypeInformation -Encoding UTF8
$summaryRows | ConvertTo-Json -Depth 6 | Out-File (Join-Path $RawDir "finding-summary_$fileStamp.json") -Encoding UTF8
Write-Host ("  [FILE] finding-summary.csv  ({0} rows)" -f $summaryRows.Count) -ForegroundColor Cyan

if ($DetailLimit -gt 0) {
    $detFile = Join-Path $OutputFolder "finding-details.csv"
    $detailRows | Export-Csv -Path $detFile -NoTypeInformation -Encoding UTF8
    Write-Host ("  [FILE] finding-details.csv  ({0} rows)" -f $detailRows.Count) -ForegroundColor Cyan
}

# top findings to console
Write-Host ""
Write-Host "Top finding types by count:" -ForegroundColor Yellow
$summaryRows | Sort-Object Count -Descending | Select-Object -First 10 Environment, FindingType, Count | Format-Table -AutoSize

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CSV: $sumFile" -ForegroundColor Gray
if ($DetailLimit -le 0) {
    Write-Host "  (run with -DetailLimit 500 to also pull per-principal rows)" -ForegroundColor DarkGray
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
