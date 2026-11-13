# ===================================================================
# BHE API Authentication Test - .env Edition
# ===================================================================
# Reads BHE_API_URL, BHE_TOKEN_ID and BHE_TOKEN_KEY from a .env file
# instead of auto-detecting the collector's settings.json / auth.json.
# Use this to verify API auth before wiring up the Power BI extract.
# ===================================================================

param(
    # Path to the .env file. Defaults to a .env sitting next to this script.
    [string]$EnvPath
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BHE API Authentication Test (.env)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ===================================================================
# RESOLVE .ENV PATH
# ===================================================================

if (-not $EnvPath) {
    if ($PSScriptRoot) {
        $EnvPath = Join-Path $PSScriptRoot ".env"
    }
    else {
        $EnvPath = Join-Path (Get-Location) ".env"
    }
}

Write-Host "STEP 1: Loading .env file" -ForegroundColor Yellow
Write-Host "  Path: $EnvPath"

if (-not (Test-Path $EnvPath)) {
    Write-Host "  [FAIL] .env file not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Create a .env file with these three lines:" -ForegroundColor Yellow
    Write-Host "    BHE_API_URL=greatbits.bloodhoundenterprise.io" -ForegroundColor Gray
    Write-Host "    BHE_TOKEN_ID=your-token-id-here" -ForegroundColor Gray
    Write-Host "    BHE_TOKEN_KEY=your-token-key-here" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Or specify a path: .\Test-BHE-API-FromEnv.ps1 -EnvPath 'C:\SDH_SO_LAB\_BHE-PowerBI\.env'" -ForegroundColor Cyan
    exit 1
}

# ===================================================================
# .ENV PARSER
# ===================================================================
# Skips blank lines and # comments, splits on the FIRST '=',
# trims whitespace, and strips surrounding single/double quotes.

function Import-DotEnv {
    param([string]$Path)

    $envVars = @{}

    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()

        # Skip blanks and comments
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }

        # Allow an optional leading "export "
        if ($trimmed.StartsWith("export ")) {
            $trimmed = $trimmed.Substring(7).Trim()
        }

        # Split on first '='
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }

        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim()

        # Strip a single matched pair of surrounding quotes
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }

        $envVars[$key] = $val
    }

    return $envVars
}

try {
    $envData = Import-DotEnv -Path $EnvPath
    Write-Host "  [PASS] .env loaded ($($envData.Keys.Count) keys)" -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Could not parse .env: $_" -ForegroundColor Red
    exit 1
}

# ===================================================================
# READ REQUIRED VALUES
# ===================================================================

$restEndpoint = $envData["BHE_API_URL"]
$tokenId      = $envData["BHE_TOKEN_ID"]
$tokenKey     = $envData["BHE_TOKEN_KEY"]

Write-Host ""
Write-Host "STEP 2: Validating required keys" -ForegroundColor Yellow

$missing = @()
if ([string]::IsNullOrWhiteSpace($restEndpoint)) { $missing += "BHE_API_URL" }
if ([string]::IsNullOrWhiteSpace($tokenId))      { $missing += "BHE_TOKEN_ID" }
if ([string]::IsNullOrWhiteSpace($tokenKey))     { $missing += "BHE_TOKEN_KEY" }

if ($missing.Count -gt 0) {
    Write-Host "  [FAIL] Missing key(s) in .env: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "  [PASS] BHE_API_URL   : $restEndpoint" -ForegroundColor Green
Write-Host "  [PASS] BHE_TOKEN_ID  : $($tokenId.Substring(0, [Math]::Min(8, $tokenId.Length)))..." -ForegroundColor Green
Write-Host "  [PASS] BHE_TOKEN_KEY : ***hidden***" -ForegroundColor Green
Write-Host ""

# ===================================================================
# NORMALIZE URL
# ===================================================================

Write-Host "STEP 3: Normalizing URL" -ForegroundColor Yellow
Write-Host "  Original: $restEndpoint"

# Add https:// if no scheme present
if (-not $restEndpoint.StartsWith("http://") -and -not $restEndpoint.StartsWith("https://")) {
    $restEndpoint = "https://$restEndpoint"
    Write-Host "  [INFO] Added https:// prefix" -ForegroundColor Cyan
}

# Remove trailing slash
$restEndpoint = $restEndpoint.TrimEnd('/')

Write-Host "  Normalized: $restEndpoint" -ForegroundColor Green
Write-Host ""

# ===================================================================
# HMAC SIGNATURE FUNCTION (unchanged - 3-step chained HMAC-SHA256)
# ===================================================================

function Get-BHEHMACSignature {
    param(
        [string]$TokenId,
        [string]$TokenKey,
        [string]$Method,
        [string]$Uri
    )

    try {
        # Parse URI to get path and query
        $uriObj = [System.Uri]$Uri
        $endpoint = $uriObj.PathAndQuery

        # Generate timestamp: 2026-02-04T17:30:00+00:00
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss+00:00")

        # DateKey is first 13 characters (e.g., "2026-02-04T17")
        $dateKey = $timestamp.Substring(0, 13)

        # Step 1: HMAC(token_key, METHOD+ENDPOINT)
        $hmac1 = New-Object System.Security.Cryptography.HMACSHA256
        $hmac1.Key = [System.Text.Encoding]::UTF8.GetBytes($TokenKey)
        $step1Input = "$Method$endpoint"
        $hash1 = $hmac1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($step1Input))

        # Step 2: HMAC(hash1, DateKey)
        $hmac2 = New-Object System.Security.Cryptography.HMACSHA256
        $hmac2.Key = $hash1
        $hash2 = $hmac2.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dateKey))

        # Step 3: HMAC(hash2, empty body)
        $hmac3 = New-Object System.Security.Cryptography.HMACSHA256
        $hmac3.Key = $hash2
        $hash3 = $hmac3.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(""))

        # Base64 encode final hash
        $signature = [System.Convert]::ToBase64String($hash3)

        return @{
            "Authorization" = "bhesignature $TokenId"
            "RequestDate"   = $timestamp
            "Signature"     = $signature
            "Content-Type"  = "application/json"
        }
    }
    catch {
        Write-Host "  [ERROR] HMAC generation failed: $_" -ForegroundColor Red
        return $null
    }
}

# ===================================================================
# TEST /API/V2/SELF (WITH HMAC AUTH)
# ===================================================================

Write-Host "STEP 4: Testing /api/v2/self (with HMAC auth)" -ForegroundColor Yellow

$selfUrl = "$restEndpoint/api/v2/self"
Write-Host "  URL: $selfUrl"
Write-Host "  Generating HMAC signature..."

$headers = Get-BHEHMACSignature -TokenId $tokenId -TokenKey $tokenKey -Method "GET" -Uri $selfUrl

if (-not $headers) {
    Write-Host "  [FAIL] HMAC signature generation failed" -ForegroundColor Red
    exit 1
}

Write-Host "  Signature: $($headers.Signature.Substring(0,20))..." -ForegroundColor Gray
Write-Host "  Sending authenticated request..."

try {
    $selfResponse = Invoke-RestMethod -Uri $selfUrl -Method GET -Headers $headers -TimeoutSec 10 -ErrorAction Stop

    Write-Host ""
    Write-Host "  SUCCESS!" -ForegroundColor Green
    Write-Host ""

    if ($selfResponse.data -and $selfResponse.data.email_address) {
        Write-Host "  Authenticated as: $($selfResponse.data.email_address)" -ForegroundColor Cyan
    }
    else {
        Write-Host "  Authenticated (but unexpected response format)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  API authentication is working correctly!" -ForegroundColor Green
}
catch {
    $statusCode = $null
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
    }

    Write-Host ""
    Write-Host "  FAILED!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red

    if ($statusCode -eq 401) {
        Write-Host ""
        Write-Host "  401 Unauthorized - Possible causes:" -ForegroundColor Yellow
        Write-Host "    1. Invalid Token ID or Token Key" -ForegroundColor Gray
        Write-Host "    2. Token has expired or been revoked" -ForegroundColor Gray
        Write-Host "    3. Time synchronization issue" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Yellow
        Write-Host "    - Check time sync: w32tm /query /status" -ForegroundColor Gray
        Write-Host "    - Resync time: w32tm /resync /rediscover" -ForegroundColor Gray
        Write-Host "    - Verify BHE_TOKEN_ID / BHE_TOKEN_KEY in .env" -ForegroundColor Gray
        Write-Host "    - Generate new API token in BHE console" -ForegroundColor Gray
    }
    elseif ($statusCode -eq 403) {
        Write-Host ""
        Write-Host "  403 Forbidden - Valid credentials but insufficient permissions" -ForegroundColor Yellow
    }
    else {
        Write-Host ""
        Write-Host "  Unexpected error occurred (HTTP $statusCode)" -ForegroundColor Yellow
    }

    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Test Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
