# ===================================================================
# Launch-BHEPowerBI.ps1
# ===================================================================
# Menu for SELECTIVE runs - pick individual collectors based on which
# dashboard widgets you want data for.
#
# Full/scheduled runs are NOT reimplemented here - they delegate to
# Update-BHEData.ps1, which already does this better (environment
# change detection, transcript logging, per-step timing, proper exit
# codes for Task Scheduler). Update-BHEData.ps1 in turn runs
# Invoke-BHEExtract.ps1 before Flatten-BHEData.ps1, since Flatten
# depends on Extract's output.
#
# Requires: Collectors.manifest.json in the same folder, .env in
# the same folder, and each Script listed in the manifest present
# alongside this file.
# ===================================================================

param(
    [switch]$All,               # delegates to Update-BHEData.ps1
    [switch]$RegisterTask,      # walk through creating a scheduled task, then exit
    [switch]$SkipDashboardPrompt
)

$ErrorActionPreference = "Continue"   # one bad collector shouldn't kill the rest
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$ManifestPath  = Join-Path $Root "Collectors.manifest.json"
$UpdateScript  = Join-Path $Root "Update-BHEData.ps1"

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FAIL] Collectors.manifest.json not found next to this script." -ForegroundColor Red
    exit 1
}
$Collectors = Get-Content $ManifestPath -Raw | ConvertFrom-Json

function Show-Menu {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  BH-PowerPupBI" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $Collectors.Count; $i++) {
        $c = $Collectors[$i]
        Write-Host ("  [{0}] {1,-30} - {2}" -f ($i + 1), $c.Name, $c.Description) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  [A] Run everything via Update-BHEData.ps1 (recommended - handles ordering/logging)" -ForegroundColor Yellow
    Write-Host "  [Q] Quit" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Note: picking individual numbers runs ONLY those scripts, in the order listed" -ForegroundColor DarkGray
    Write-Host "  above. If you pick Flatten Extract (2), make sure Generic Extract (1) is included" -ForegroundColor DarkGray
    Write-Host "  too, or has already been run - Flatten reads Extract's output." -ForegroundColor DarkGray
}

function Invoke-Collector {
    param($Collector)
    $scriptPath = Join-Path $Root $Collector.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host ("  [SKIP] {0} - script not found at {1}" -f $Collector.Name, $scriptPath) -ForegroundColor DarkYellow
        return $false
    }
    Write-Host ""
    Write-Host ("--- Running: {0} ---" -f $Collector.Name) -ForegroundColor Cyan
    try {
        & $scriptPath
        return $true
    } catch {
        Write-Host ("  [FAIL] {0}: {1}" -f $Collector.Name, $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Show-RunSummary {
    param([hashtable]$Results)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Run summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    $Results.GetEnumerator() | ForEach-Object {
        $status = if ($_.Value) { "[OK]" } else { "[FAILED]" }
        $color  = if ($_.Value) { "Green" } else { "Red" }
        Write-Host ("  {0,-10} {1}" -f $status, $_.Key) -ForegroundColor $color
    }
}

function Show-DashboardPrompt {
    $pbi = Get-ChildItem -Path $Root -Filter "*.pbix" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pbi) {
        $open = Read-Host "`nOpen $($pbi.Name) now? (Y/N)"
        if ($open -match '^[Yy]') {
            Invoke-Item $pbi.FullName
            Write-Host "  Once Power BI Desktop opens, click Refresh (Home ribbon) to pull in the new data." -ForegroundColor Gray
        }
    } else {
        Write-Host "`n  No .pbix found in this folder - open your dashboard file manually and click Refresh." -ForegroundColor Gray
    }
}

function Invoke-FullRun {
    if (-not (Test-Path $UpdateScript)) {
        Write-Host "[FAIL] Update-BHEData.ps1 not found next to this script - can't run the full sequence." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "Delegating to Update-BHEData.ps1 ..." -ForegroundColor Cyan
    & $UpdateScript
    if (-not $SkipDashboardPrompt) { Show-DashboardPrompt }
    exit $LASTEXITCODE
}

# ----- scheduled task setup (walk-through, then exit) ---------------
if ($RegisterTask) {
    Write-Host ""
    Write-Host "Scheduled Task Setup" -ForegroundColor Cyan
    Write-Host "Registers a task that runs Update-BHEData.ps1 on a schedule," -ForegroundColor Gray
    Write-Host "keeping your Power BI data folder fresh for scheduled refresh." -ForegroundColor Gray
    Write-Host ""
    if (-not (Test-Path $UpdateScript)) {
        Write-Host "[FAIL] Update-BHEData.ps1 not found next to this script - nothing to schedule." -ForegroundColor Red
        exit 1
    }
    $freq = Read-Host "Run how often - (D)aily or (H)ourly? [D]"
    if ([string]::IsNullOrWhiteSpace($freq)) { $freq = "D" }
    $timeOfDay = "06:00"
    if ($freq -match '^[Dd]') {
        $timeOfDay = Read-Host "Daily run time (24hr HH:mm) [06:00]"
        if ([string]::IsNullOrWhiteSpace($timeOfDay)) { $timeOfDay = "06:00" }
    }

    $taskName = "BHE-PowerBI-DataRefresh"
    $psExe    = (Get-Process -Id $PID).Path
    $action   = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`""

    if ($freq -match '^[Hh]') {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
    } else {
        $trigger = New-ScheduledTaskTrigger -Daily -At $timeOfDay
    }

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "Refreshes BHE Power BI data folder via Update-BHEData.ps1" -Force | Out-Null
        Write-Host ("  [OK] Scheduled task '{0}' registered, running Update-BHEData.ps1." -f $taskName) -ForegroundColor Green
        Write-Host "  Check/edit it any time in Task Scheduler under the root task folder." -ForegroundColor Gray
    } catch {
        Write-Host ("  [FAIL] Could not register task: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "  Try running this script as Administrator." -ForegroundColor Yellow
    }
    exit 0
}

# ----- non-interactive full run ---------------------------------------
if ($All) { Invoke-FullRun }

# ----- interactive menu ------------------------------------------------
Show-Menu
$choice = Read-Host "Select collector number(s) (comma-separated), A for all, or Q to quit"

if ($choice -match '^[Qq]') { exit 0 }
if ($choice -match '^[Aa]') { Invoke-FullRun }

$picked = $choice -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
$toRun = @()
foreach ($p in $picked) {
    $idx = [int]$p - 1
    if ($idx -ge 0 -and $idx -lt $Collectors.Count) { $toRun += $Collectors[$idx] }
}

if ($toRun.Count -eq 0) {
    Write-Host "  Nothing selected - exiting." -ForegroundColor Yellow
    exit 0
}

$results = @{}
foreach ($c in $toRun) { $results[$c.Name] = Invoke-Collector -Collector $c }
Show-RunSummary -Results $results

if (-not $SkipDashboardPrompt) { Show-DashboardPrompt }
