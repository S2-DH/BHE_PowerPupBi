# ===================================================================
# Fix-DataFolderPaths.ps1
# ===================================================================
# One-time fix: replaces the hardcoded old-folder default (OutputFolder
# or DataFolder, both pointing at the old _BHE-PowerBI\Data path) with a
# version that resolves to wherever the script actually lives instead.
#
# Backs up every file it touches to <name>.ps1.bak before changing it.
# Safe to run more than once - won't match already-fixed lines.
#
# Usage: run this FROM INSIDE the toolkit folder (or pass -Path).
# ===================================================================

param(
    [string]$Path = "."
)

$pattern     = '(\[string\]\$(?:OutputFolder|DataFolder)\s*=\s*)"C:\\SDH_SO_LAB\\_BHE-PowerBI\\Data"'
$replacement = '$1$(if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { "C:\SDH_SO_LAB\_BHE-PowerBI\Data" })'

$files = Get-ChildItem -Path $Path -Filter "*.ps1" -File | Where-Object { $_.Name -ne "Fix-DataFolderPaths.ps1" }
$fixedCount = 0

Write-Host ""
Write-Host "Scanning $($files.Count) .ps1 file(s) in $Path ..." -ForegroundColor Cyan
Write-Host ""

foreach ($f in $files) {
    $content = Get-Content -Path $f.FullName -Raw
    if ($content -match $pattern) {
        Copy-Item -Path $f.FullName -Destination "$($f.FullName).bak" -Force
        $newContent = [regex]::Replace($content, $pattern, $replacement)
        Set-Content -Path $f.FullName -Value $newContent -Encoding UTF8 -NoNewline
        Write-Host ("  [FIXED] {0}" -f $f.Name) -ForegroundColor Green
        $fixedCount++
    }
}

Write-Host ""
if ($fixedCount -eq 0) {
    Write-Host "Nothing to fix - no hardcoded old-path defaults found." -ForegroundColor Gray
} else {
    Write-Host ("Fixed {0} file(s). Originals backed up as <name>.ps1.bak" -f $fixedCount) -ForegroundColor Cyan
    Write-Host "Verify with:" -ForegroundColor Gray
    Write-Host "  Select-String -Path *.ps1 -Pattern 'SDH_SO_LAB\_BHE-PowerBI'" -ForegroundColor Gray
    Write-Host "(should only show this script and the Test-BHE-API help text, if anything)" -ForegroundColor Gray
}
Write-Host ""
