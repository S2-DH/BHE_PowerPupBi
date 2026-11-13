<#
.SYNOPSIS
    Pulls posture-history and attack-path sparkline data from a BloodHound
    ENTERPRISE instance and writes two flat CSVs for the Power BI dashboard.

.OUTPUTS
    posture-history.csv          EnvironmentId, Environment, DataType, Date, Value
    attack-path-sparklines.csv   EnvironmentId, Environment, Finding, Date,
                                 CompositeRisk, FindingCount, ImpactedAssetCount

.NOTES
    Credentials are read from a .env file next to the script by default, in the
    same format as BHE-API-Console.ps1:
        BHE_API_ID="your-token-id"
        BHE_API_KEY="your-token-key"
        BHE_URL="http://localhost:8080"
    Any -BHEUrl / -TokenId / -TokenKey passed on the command line overrides .env.

    Generate an API token in the BHE UI (Administration -> API Key Management ->
    Create Token). You get a Token ID and a Token Key.

.EXAMPLE
    # Uses .env in the same folder
    .\Get-BHEPosture.ps1 -Days 365

.EXAMPLE
    # Point at a custom .env, or override creds directly
    .\Get-BHEPosture.ps1 -EnvFile "C:\creds\bhe.env"
    .\Get-BHEPosture.ps1 -BHEUrl "http://localhost:8080" -TokenId "xxxx" -TokenKey "yyyy"
#>

param(
    # Credentials are read from a .env file by default (same format as your
    # BHE-API-Console.ps1). Any explicit param below overrides the .env value.
    [string]$EnvFile   = (Join-Path $PSScriptRoot ".env"),
    [string]$BHEUrl,
    [string]$TokenId,
    [string]$TokenKey,
    [int]   $Days      = 365,
    [string]$OutDir,
    [switch]$SkipCertCheck
)

if (-not $OutDir) {
    $OutDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { Join-Path (Get-Location) "Data" }
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- .env loader; handles BOM, single/double quotes, and an optional 'export ' prefix ---
function Import-EnvFile {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    $raw = Get-Content -Raw -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return $vars }
    $raw = $raw.TrimStart([char]0xFEFF)               # strip UTF-8 BOM if present
    foreach ($line in ($raw -split "`r?`n")) {
        $t = $line.Trim().TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith('#')) { continue }
        $t = $t -replace '^(?i:export)\s+', ''        # drop optional leading 'export '
        if ($t -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"').Trim("'")
            $vars[$k] = $v
        }
    }
    return $vars
}

function Get-EnvValue {
    param([hashtable]$Vars, [string[]]$Names)
    foreach ($n in $Names) {
        if ($Vars.ContainsKey($n) -and -not [string]::IsNullOrWhiteSpace($Vars[$n])) { return $Vars[$n] }
    }
    return $null
}

$envVars = Import-EnvFile -Path $EnvFile
if ($envVars.Count -gt 0) {
    Write-Host ("Loaded {0}" -f $EnvFile) -ForegroundColor Gray
    Write-Host ("  keys found: {0}" -f (($envVars.Keys | Sort-Object) -join ', ')) -ForegroundColor DarkGray
} else {
    Write-Host ("No readable keys in {0}" -f $EnvFile) -ForegroundColor Yellow
}

if (-not $BHEUrl)   { $BHEUrl   = Get-EnvValue $envVars @('BHE_API_URL','BHE_URL','BHE_DOMAIN','BHE_ENDPOINT','BHE_REST_ENDPOINT','REST_ENDPOINT') }
if (-not $TokenId)  { $TokenId  = Get-EnvValue $envVars @('BHE_API_ID','BHE_TOKEN_ID','BHE_TOKENID','TOKEN_ID','BHE_ID') }
if (-not $TokenKey) { $TokenKey = Get-EnvValue $envVars @('BHE_API_KEY','BHE_TOKEN_KEY','BHE_TOKENKEY','TOKEN_KEY','BHE_KEY') }

if (-not $BHEUrl -or -not $TokenId -or -not $TokenKey) {
    Write-Host ""
    Write-Error ("Missing credentials. The script needs a URL, token ID and token key.`n" +
                 "  URL   : {0}`n  ID    : {1}`n  KEY   : {2}`n" -f `
                 $(if($BHEUrl){'found'}else{'MISSING'}),
                 $(if($TokenId){'found'}else{'MISSING'}),
                 $(if($TokenKey){'found'}else{'MISSING'})) 
    Write-Host "Expected keys in .env: BHE_URL, BHE_API_ID, BHE_API_KEY. Compare against the 'keys found' line above." -ForegroundColor Yellow
    return
}

# Accept BHE_URL with or without a scheme; default to https for tenant URLs
if ($BHEUrl -notmatch '^https?://') { $BHEUrl = "https://$BHEUrl" }
$BHEUrl = $BHEUrl.TrimEnd('/')

# --- Self-signed cert bypass (on-prem instances). PS 5.1 route below;
#     on PowerShell 7 you could instead add -SkipCertificateCheck to the calls. ---
if ($SkipCertCheck) {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ErrorAction SilentlyContinue
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    } catch {}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# --- BHE signed-request auth (three-step chained HMAC-SHA256) ---
function Invoke-BHESignedRequest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri   # relative path + query, e.g. /api/v2/...
    )

    $requestDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

    # 1) OperationKey: HMAC(key=TokenKey) over METHOD + URI
    $h = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($TokenKey))
    $opKey = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Method + $Uri))

    # 2) DateKey: HMAC(key=OperationKey) over the RFC3339 datetime truncated to the hour (first 13 chars)
    $h = [System.Security.Cryptography.HMACSHA256]::new($opKey)
    $dateKey = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($requestDate.Substring(0, 13)))

    # 3) Body signing: HMAC(key=DateKey) over the body (empty for GET)
    $h = [System.Security.Cryptography.HMACSHA256]::new($dateKey)
    $sig = $h.ComputeHash([byte[]]@())
    $signature = [Convert]::ToBase64String($sig)

    $headers = @{
        Authorization = "bhesignature $TokenId"
        RequestDate   = $requestDate
        Signature     = $signature
        Prefer        = "wait=60"
    }

    Invoke-RestMethod -Method $Method -Uri ($BHEUrl + $Uri) -Headers $headers -ContentType "application/json"
}

# --- Time window (escaped once, reused for signing + sending so they match) ---
$startRaw = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString("yyyy-MM-ddTHH:mm:ssZ")
$endRaw   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$start    = [uri]::EscapeDataString($startRaw)
$end      = [uri]::EscapeDataString($endRaw)

Write-Host "Connecting to $BHEUrl ..." -ForegroundColor Cyan

# --- Enumerate environments ---
try {
    $domains = (Invoke-BHESignedRequest -Method GET -Uri "/api/v2/available-domains").data
} catch {
    Write-Error "Could not list environments. Check URL / token / that this is an Enterprise instance. $($_.Exception.Message)"
    return
}
Write-Host ("Found {0} environment(s)." -f $domains.Count) -ForegroundColor Green

# ============================================================
# 1) POSTURE HISTORY  ->  posture-history.csv
# ============================================================
$dataTypes = @("exposure","findings","attack-paths","assets","session-completeness","group-completeness")
$postureRows = New-Object System.Collections.Generic.List[object]

foreach ($d in $domains) {
    foreach ($dt in $dataTypes) {
        $uri = "/api/v2/posture-history/$dt`?environments=$($d.id)&start=$start&end=$end"
        try {
            $resp = Invoke-BHESignedRequest -Method GET -Uri $uri
            foreach ($pt in $resp.data) {
                $postureRows.Add([pscustomobject]@{
                    EnvironmentId = $d.id
                    Environment   = $d.name
                    DataType      = $dt
                    Date          = $pt.date
                    Value         = $pt.value
                })
            }
            Write-Host ("  posture-history [{0}] {1}: {2} points" -f $dt, $d.name, $resp.data.Count)
        } catch {
            Write-Warning ("  posture-history [{0}] {1}: {2}" -f $dt, $d.name, $_.Exception.Message)
        }
    }
}

$posturePath = Join-Path $OutDir "posture-history.csv"
$postureRows | Export-Csv -Path $posturePath -NoTypeInformation -Encoding UTF8
Write-Host ("Wrote {0} rows -> {1}" -f $postureRows.Count, $posturePath) -ForegroundColor Green

# ============================================================
# 2) ATTACK-PATH SPARKLINES  ->  attack-path-sparklines.csv
# ============================================================
$sparkRows = New-Object System.Collections.Generic.List[object]

foreach ($d in $domains) {
    try {
        $types = (Invoke-BHESignedRequest -Method GET -Uri "/api/v2/domains/$($d.id)/available-types").data
    } catch {
        Write-Warning ("  available-types {0}: {1}" -f $d.name, $_.Exception.Message)
        $types = @()
    }

    foreach ($ft in $types) {
        $findingEnc = [uri]::EscapeDataString($ft)
        $uri = "/api/v2/domains/$($d.id)/sparkline`?finding=$findingEnc&from=$start&to=$end"
        try {
            $resp = Invoke-BHESignedRequest -Method GET -Uri $uri
            foreach ($pt in $resp.data) {
                $sparkRows.Add([pscustomobject]@{
                    EnvironmentId      = $d.id
                    Environment        = $d.name
                    Finding            = $ft
                    Date               = $pt.updated_at
                    CompositeRisk      = $pt.CompositeRisk
                    FindingCount       = $pt.FindingCount
                    ImpactedAssetCount = $pt.ImpactedAssetCount
                })
            }
        } catch {
            Write-Warning ("  sparkline [{0}] {1}: {2}" -f $ft, $d.name, $_.Exception.Message)
        }
    }
    Write-Host ("  sparklines {0}: {1} finding type(s) processed" -f $d.name, $types.Count)
}

$sparkPath = Join-Path $OutDir "attack-path-sparklines.csv"
$sparkRows | Export-Csv -Path $sparkPath -NoTypeInformation -Encoding UTF8
Write-Host ("Wrote {0} rows -> {1}" -f $sparkRows.Count, $sparkPath) -ForegroundColor Green

Write-Host "`nDone. Load both CSVs into Power BI and relate EnvironmentId to your available-domains table." -ForegroundColor Cyan
