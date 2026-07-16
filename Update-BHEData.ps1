# ===================================================================
# Update-BHEData.ps1  -  BHE Power BI extract orchestrator
# ===================================================================
# Runs every BHE puller in one pass so a Power BI refresh always sees
# a consistent, fully-current set of CSVs. Point a single Task
# Scheduler job at this script and the whole dashboard stays fresh.
#
# Key behaviours:
#   * Each child script is isolated in try/catch - one failure does
#     NOT stop the rest of the run.
#   * Before running, it enumerates /api/v2/available-domains and
#     compares the environment count against the previous run. If a
#     new environment has appeared (or one has gone), it says so
#     loudly - that's your cue that a Power BI refresh is worthwhile.
#   * Every run is transcript-logged under <DataFolder>\logs\.
#   * A summary table at the end shows which steps passed/failed and
#     how long each took.
#
# Usage:
#   .\Update-BHEData.ps1                      # normal scheduled run
#   .\Update-BHEData.ps1 -DetailLimit 1000    # deeper findings pull
#   .\Update-BHEData.ps1 -SkipExtract         # skip generic extract+flatten
# ===================================================================

param(
    [string]$EnvPath,
    [string]$ScriptDir  = $PSScriptRoot,
    [string]$DataFolder,
    [int]   $DetailLimit = 500,
    [switch]$SkipExtract       # skip Invoke-BHEExtract + Flatten-BHEData
)

$ErrorActionPreference = "Stop"
if (-not $ScriptDir) { $ScriptDir = Get-Location }
if (-not $DataFolder) { $DataFolder = Join-Path $ScriptDir "Data" }

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host " Update-BHEData : BHE -> Power BI extract orchestrator"      -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan

# ----- resolve .env -------------------------------------------------
if (-not $EnvPath) {
    if ($ScriptDir) { $EnvPath = Join-Path $ScriptDir ".env" }
    else            { $EnvPath = Join-Path (Get-Location) ".env" }
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

# ----- HMAC (same 3-step chained HMAC-SHA256 as the pullers) --------
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

# ----- output + logging ---------------------------------------------
$LogDir = Join-Path $DataFolder "logs"
foreach ($d in @($DataFolder, $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$runStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile  = Join-Path $LogDir "update-bhe_$runStamp.log"
try { Start-Transcript -Path $logFile -Force | Out-Null } catch {}

$runStart = Get-Date

# ===================================================================
# PRE-FLIGHT: environment detection
# ===================================================================
# Enumerate environments live and compare to the last run. This is
# what makes new environments self-announcing: if the count changes,
# the run shouts and lists what appeared/disappeared.
Write-Host ""
Write-Host "PRE-FLIGHT: environment detection" -ForegroundColor Yellow

$currentEnvs = @()
try {
    $resp    = Invoke-BHERequest -Path "/api/v2/available-domains"
    $domains = if ($null -ne $resp.data) { $resp.data } else { $resp }
    $currentEnvs = @($domains | ForEach-Object {
        $n = $_.PSObject.Properties['name'];  $nv = if ($n) { $n.Value } else { $null }
        $i = $_.PSObject.Properties['id'];    $iv = if ($i) { $i.Value } else { $null }
        if ($nv) { $nv } elseif ($iv) { $iv }
    } | Where-Object { $_ })
    Write-Host ("  [OK] {0} environment(s): {1}" -f $currentEnvs.Count, ($currentEnvs -join ", ")) -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] Could not enumerate environments: $($_.Exception.Message)" -ForegroundColor DarkYellow
    Write-Host "         Continuing - pullers will each enumerate independently." -ForegroundColor DarkGray
}

$statePath = Join-Path $DataFolder ".bhe-env-state.json"
if ($currentEnvs.Count -gt 0) {
    $prevEnvs = @()
    if (Test-Path $statePath) {
        try { $prevEnvs = @((Get-Content $statePath -Raw | ConvertFrom-Json).environments) } catch { $prevEnvs = @() }
    }

    if ($prevEnvs.Count -eq 0) {
        Write-Host "  [INFO] No previous environment state on file - baselining now." -ForegroundColor Gray
    }
    else {
        $added   = @($currentEnvs | Where-Object { $_ -notin $prevEnvs })
        $removed = @($prevEnvs    | Where-Object { $_ -notin $currentEnvs })
        if ($added.Count -eq 0 -and $removed.Count -eq 0) {
            Write-Host ("  [INFO] Environment set unchanged since last run ({0})." -f $prevEnvs.Count) -ForegroundColor Gray
        }
        else {
            Write-Host "  ***************************************************" -ForegroundColor Magenta
            Write-Host ("  *** ENVIRONMENT CHANGE DETECTED  ({0} -> {1})" -f $prevEnvs.Count, $currentEnvs.Count) -ForegroundColor Magenta
            if ($added.Count)   { Write-Host ("  ***   ADDED  : {0}" -f ($added   -join ", ")) -ForegroundColor Magenta }
            if ($removed.Count) { Write-Host ("  ***   REMOVED: {0}" -f ($removed -join ", ")) -ForegroundColor Magenta }
            Write-Host "  ***   -> Refresh Power BI after this run completes." -ForegroundColor Magenta
            Write-Host "  ***************************************************" -ForegroundColor Magenta
        }
    }

    # persist current state for next run
    try {
        [pscustomobject]@{
            lastRun      = (Get-Date).ToString("s")
            count        = $currentEnvs.Count
            environments = $currentEnvs
        } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
    } catch { Write-Host "  [WARN] Could not write env state file." -ForegroundColor DarkYellow }
}

# ===================================================================
# RUN THE PULLERS
# ===================================================================
# Each entry: display name, script file, and an argument hashtable.
# Order matters where one step feeds another (Extract -> Flatten).
$steps = @()

if (-not $SkipExtract) {
    $steps += @{ Name = "Generic extract"   ; Script = "Invoke-BHEExtract.ps1"     ; Args = @{} }
    $steps += @{ Name = "Flatten extract"   ; Script = "Flatten-BHEData.ps1"       ; Args = @{ DataFolder = $DataFolder } }
}
$steps += @{ Name = "Findings"          ; Script = "Get-BHEFindings.ps1"       ; Args = @{ DetailLimit = $DetailLimit } }
$steps += @{ Name = "Posture history"   ; Script = "Get-BHEPosture.ps1"        ; Args = @{} }   # writes to its own default location
$steps += @{ Name = "Panels / TierZero" ; Script = "Get-BHEPanels.ps1"         ; Args = @{} }
$steps += @{ Name = "Collector health"  ; Script = "Get-BHECollectorHealth.ps1"; Args = @{} }
$steps += @{ Name = "Tenant / version"  ; Script = "Get-BHEVersion.ps1"        ; Args = @{} }

$results = New-Object System.Collections.ArrayList

foreach ($step in $steps) {
    $scriptPath = Join-Path $ScriptDir $step.Script
    Write-Host ""
    Write-Host ("-----------------------------------------------------------") -ForegroundColor DarkCyan
    Write-Host (" STEP: {0}  ({1})" -f $step.Name, $step.Script) -ForegroundColor White
    Write-Host ("-----------------------------------------------------------") -ForegroundColor DarkCyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = "OK"; $note = ""

    if (-not (Test-Path $scriptPath)) {
        $status = "MISSING"; $note = "script not found"
        Write-Host ("  [SKIP] {0} not found in {1}" -f $step.Script, $ScriptDir) -ForegroundColor DarkYellow
    }
    else {
        try {
            $splat = $step.Args        # splatting requires a plain variable, not a property expression
            $global:LASTEXITCODE = 0   # reset - it's sticky and would otherwise carry over a stale value from an earlier step/session
            & $scriptPath @splat *>&1 | Out-String | Write-Host
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { $status = "FAIL"; $note = "exit $LASTEXITCODE" }
        }
        catch {
            $status = "FAIL"; $note = $_.Exception.Message
            Write-Host ("  [FAIL] {0}: {1}" -f $step.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }

    $sw.Stop()
    [void]$results.Add([pscustomobject]@{
        Step    = $step.Name
        Status  = $status
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Note    = $note
    })
}

# ===================================================================
# SUMMARY
# ===================================================================
$runEnd = Get-Date
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host " RUN SUMMARY" -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize Step, Status, Seconds, Note | Out-String | ForEach-Object { Write-Host $_ }

$okCount   = @($results | Where-Object { $_.Status -eq "OK" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$skipCount = @($results | Where-Object { $_.Status -eq "MISSING" }).Count
$total     = [math]::Round(($runEnd - $runStart).TotalSeconds, 1)

$col = if ($failCount -gt 0) { "Yellow" } else { "Green" }
Write-Host ("  {0} ok, {1} failed, {2} missing  -  {3}s total" -f $okCount, $failCount, $skipCount, $total) -ForegroundColor $col
Write-Host ("  Log: {0}" -f $logFile) -ForegroundColor Gray
Write-Host ""

try { Stop-Transcript | Out-Null } catch {}

# non-zero exit if anything failed, so Task Scheduler can flag it
if ($failCount -gt 0) { exit 1 } else { exit 0 }
