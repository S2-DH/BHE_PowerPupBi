# ===================================================================
# Get-BHEVersion.ps1  -  version + tenant summary (dashboard top-right)
# ===================================================================
# Pulls /api/v2/version plus a few tenant facts and writes a single-row
# tenant-info.csv you can drop into a Card / small table top-right.
# ===================================================================

param(
    [string]$EnvPath,
    [string]$OutputFolder = "C:\SDH_SO_LAB\_BHE-PowerBI\Data"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE Version + Tenant Info" -ForegroundColor Cyan
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

# ----- version -----------------------------------------------------
# NOTE: version lives at /api/version (NOT /api/v2/version)
Write-Host "Version..." -ForegroundColor Yellow
$serverVer = $null; $apiVer = $null
try {
    $v = Invoke-BHERequest -Path "/api/version"
    $v | ConvertTo-Json -Depth 10 | Out-File (Join-Path $RawDir "version_$fileStamp.json") -Encoding UTF8
    $vd = if ($null -ne $v.data) { $v.data } else { $v }
    $serverVer = Get-Prop $vd @('server_version','version')
    $apiVer    = Get-Prop $vd @('api','API','current_version')
    # api may itself be an object {current_version: "v2"}
    if ($apiVer -and $apiVer.PSObject -and $apiVer.PSObject.Properties['current_version']) {
        $apiVer = $apiVer.current_version
    }
    Write-Host ("  [OK]  server {0}  api {1}" -f $serverVer, $apiVer) -ForegroundColor Green
} catch {
    Write-Host "  [WARN] /api/version error: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# ----- tenant facts ------------------------------------------------
Write-Host "Tenant facts..." -ForegroundColor Yellow
$envCount = $null; $collectorCount = $null; $whoami = $null; $tenantHost = ([System.Uri]$restEndpoint).Host

try { $dom = Invoke-BHERequest -Path "/api/v2/available-domains"; $d = if ($dom.data){$dom.data}else{$dom}; $envCount = ($d | Measure-Object).Count } catch {}
try { $cl  = Invoke-BHERequest -Path "/api/v2/clients"; $c = if ($cl.data){$cl.data}else{$cl}; $collectorCount = ($c | Measure-Object).Count } catch {}
try { $self= Invoke-BHERequest -Path "/api/v2/self"; $s = if ($self.data){$self.data}else{$self}; $whoami = Get-Prop $s @('email_address','principal_name','email') } catch {}

Write-Host ("  envs {0}  collectors {1}  user {2}" -f $envCount, $collectorCount, $whoami) -ForegroundColor Green

# ----- write single-row tenant-info.csv ----------------------------
$row = [pscustomobject][ordered]@{
    SnapshotDate  = $snapshotIso
    TenantHost    = $tenantHost
    BHEVersion    = $serverVer
    APIVersion    = $apiVer
    Environments  = $envCount
    Collectors    = $collectorCount
    LoggedInAs    = $whoami
}
$row | Export-Csv -Path (Join-Path $OutputFolder "tenant-info.csv") -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "  [FILE] tenant-info.csv" -ForegroundColor Cyan
$row | Format-List
Write-Host "  (check raw\version_*.json if BHEVersion is blank - I'll remap)" -ForegroundColor DarkGray
Write-Host ""
