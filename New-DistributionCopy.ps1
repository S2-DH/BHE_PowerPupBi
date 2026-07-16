# ===================================================================
# New-DistributionCopy.ps1
# ===================================================================
# Copies this toolkit to a new folder, stripped of everything personal
# or generated - real credentials, pulled data, logs, backup files.
# What's left is safe to zip up and hand to someone else, or push to
# a repo someone else will clone.
#
# Does NOT touch this folder - copies OUT to -Destination, leaving
# your own working copy (with real .env and Data) untouched.
# ===================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Destination
)

$ErrorActionPreference = "Stop"
$Source = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

if (Test-Path $Destination) {
    $existing = Get-ChildItem -Path $Destination -Force -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[FAIL] $Destination already exists and isn't empty. Choose a new folder or empty it first." -ForegroundColor Red
        exit 1
    }
} else {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Creating distribution copy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  From: {0}" -f $Source) -ForegroundColor Gray
Write-Host ("  To:   {0}" -f $Destination) -ForegroundColor Gray
Write-Host ""

# robocopy, not Copy-Item -Exclude: -Exclude only works reliably with a
# wildcard path, and this whole toolkit exists because of that class of
# bug already once - not repeating it here.
$robocopyArgs = @(
    $Source, $Destination,
    "/E",                                  # copy subfolders, including empty ones
    "/XD", "Data", "raw", "logs", ".git",  # exclude directories
    "/XF", "*.bak", "files.zip", ".env", "*.csv",  # exclude files - *.csv is a safety net in case any collector writes data outside Data\ (Get-BHEPosture.ps1 currently does)
    "/NFL", "/NDL", "/NJH", "/NJS"         # quiet output - just the summary
)
robocopy @robocopyArgs | Out-Null
# robocopy exit codes 0-7 are all success states (7 = files copied + some skipped);
# 8+ means real failure. Not treating any nonzero as failure - learned that lesson already.
if ($LASTEXITCODE -ge 8) {
    Write-Host "[FAIL] robocopy reported a real error (code $LASTEXITCODE)." -ForegroundColor Red
    exit 1
}
$global:LASTEXITCODE = 0

# ----- safety checks - confirm nothing sensitive made it across --------
Write-Host "Verifying the copy is clean..." -ForegroundColor Yellow
$problems = @()

if (Test-Path (Join-Path $Destination ".env"))  { $problems += ".env (real credentials) was copied - should have been excluded" }
if (Test-Path (Join-Path $Destination "Data"))   { $problems += "Data\ folder was copied - should have been excluded" }
$strayCsvs = Get-ChildItem -Path $Destination -Filter "*.csv" -File -ErrorAction SilentlyContinue
if ($strayCsvs) { $problems += ("{0} stray CSV(s) with real data made it into the copy: {1}" -f $strayCsvs.Count, (($strayCsvs.Name) -join ", ")) }
if (-not (Test-Path (Join-Path $Destination ".env.example"))) { $problems += ".env.example is MISSING - a new user won't know what keys to fill in" }
if (-not (Test-Path (Join-Path $Destination "GETTING-STARTED.md"))) { $problems += "GETTING-STARTED.md is missing" }

if ($problems.Count -gt 0) {
    Write-Host ""
    foreach ($p in $problems) { Write-Host ("  [ISSUE] {0}" -f $p) -ForegroundColor Red }
} else {
    Write-Host "  [OK] No credentials, generated data, or backup files present." -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Manual steps still needed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  1. Open the .pbix in the NEW folder in Power BI Desktop." -ForegroundColor Gray
Write-Host "  2. File -> Save As -> Power BI template (*.pbit) -> save in the same new folder." -ForegroundColor Gray
Write-Host "  3. Delete the .pbix from the new folder (keep only the .pbit - it opens empty," -ForegroundColor Gray
Write-Host "     which is the point; the .pbix still has your data cached inside it)." -ForegroundColor Gray
Write-Host "  4. Zip the folder, or push it to a new repo, and hand it over." -ForegroundColor Gray
Write-Host ""
Write-Host ("  Copy ready at: {0}" -f $Destination) -ForegroundColor Cyan
Write-Host ""
