# ===================================================================
# Flatten-BHEData.ps1
# ===================================================================
# Unwraps the nested-JSON columns that Power BI can't read:
#   audit.csv   (logs column)    -> audit-flat.csv    (Activity page)
#   clients.csv (events + token) -> clients-flat.csv  (Collectors page)
# Runs on files already in the Data folder - no API call needed.
# ===================================================================

param(
    [string]$DataFolder = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "Data" } else { "C:\SDH_SO_LAB\_BHE-PowerBI\Data" })
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Flatten BHE nested-JSON data" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----- 1. AUDIT -> audit-flat.csv ----------------------------------
$auditPath = Join-Path $DataFolder "audit.csv"
if (Test-Path $auditPath) {
    Write-Host "audit.csv -> audit-flat.csv" -ForegroundColor Yellow
    $auditRows = New-Object System.Collections.ArrayList
    $audit = Import-Csv $auditPath
    foreach ($snap in $audit) {
        if (-not $snap.logs) { continue }
        try { $entries = $snap.logs | ConvertFrom-Json } catch { Write-Host "  [WARN] could not parse logs JSON" -ForegroundColor DarkYellow; continue }
        foreach ($en in $entries) {
            $fields = $en.fields
            [void]$auditRows.Add([pscustomobject][ordered]@{
                Timestamp   = $en.created_at
                Actor       = $en.actor_name
                ActorEmail  = $en.actor_email
                Action      = $en.action
                Status      = $en.status
                SourceIP    = $en.source_ip_address
                JobId       = if ($fields) { $fields.job_id }   else { $null }
                ClientId    = if ($fields) { $fields.client_id } else { $null }
                RequestId   = $en.request_id
            })
        }
    }
    # de-dupe the success/intent pairs is optional; keep all for full audit trail
    $auditRows | Sort-Object Timestamp -Descending | Export-Csv -Path (Join-Path $DataFolder "audit-flat.csv") -NoTypeInformation -Encoding UTF8
    Write-Host ("  [FILE] audit-flat.csv ({0} events)" -f $auditRows.Count) -ForegroundColor Cyan

    # quick action breakdown to console
    Write-Host "  Actions:" -ForegroundColor Gray
    $auditRows | Group-Object Action | Sort-Object Count -Descending |
        Select-Object @{n='Action';e={$_.Name}}, Count | Format-Table -AutoSize
} else {
    Write-Host "[SKIP] audit.csv not found in $DataFolder" -ForegroundColor DarkYellow
}

# ----- 2. CLIENTS -> clients-flat.csv ------------------------------
$clientsPath = Join-Path $DataFolder "clients.csv"
if (Test-Path $clientsPath) {
    Write-Host ""
    Write-Host "clients.csv -> clients-flat.csv" -ForegroundColor Yellow
    $clientRows = New-Object System.Collections.ArrayList
    $clients = Import-Csv $clientsPath
    foreach ($c in $clients) {
        $events = $null; $token = $null
        if ($c.events) { try { $events = $c.events | ConvertFrom-Json } catch {} }
        if ($c.token)  { try { $token  = $c.token  | ConvertFrom-Json } catch {} }

        # rrule looks like "DTSTART:...\nRRULE:FREQ=DAILY;INTERVAL=1" - pull the human bits
        $rrule = if ($events) { $events.rrule } else { $null }
        $freq = $null
        if ($rrule -and $rrule -match 'FREQ=([A-Z]+)') { $freq = $Matches[1] }

        $tokenExpires = $null; $tokenLastAccess = $null
        if ($token) {
            if ($token.expires_at -and $token.expires_at.Valid) { $tokenExpires = $token.expires_at.Time }
            $tokenLastAccess = $token.last_access
        }

        [void]$clientRows.Add([pscustomobject][ordered]@{
            Name                = $c.name
            Type                = $c.type
            Hostname            = $c.hostname
            IPAddress           = $c.ip_address
            Version             = $c.version
            LastCheckin         = $c.last_checkin
            CompletedJobs       = $c.completed_job_count
            Schedule            = $freq
            RRule               = $rrule
            SessionCollection   = if ($events) { $events.session_collection }     else { $null }
            LocalGroupCollection= if ($events) { $events.local_group_collection } else { $null }
            ADStructure         = if ($events) { $events.ad_structure_collection }else { $null }
            CertServices        = if ($events) { $events.cert_services_collection}else { $null }
            AllTrustedDomains   = if ($events) { $events.all_trusted_domains }     else { $null }
            TokenLastAccess     = $tokenLastAccess
            AuthType            = $c.auth_type
        })
    }
    $clientRows | Export-Csv -Path (Join-Path $DataFolder "clients-flat.csv") -NoTypeInformation -Encoding UTF8
    Write-Host ("  [FILE] clients-flat.csv ({0} collectors)" -f $clientRows.Count) -ForegroundColor Cyan
    $clientRows | Select-Object Name, Type, Schedule, CompletedJobs, Version | Format-Table -AutoSize
} else {
    Write-Host "[SKIP] clients.csv not found in $DataFolder" -ForegroundColor DarkYellow
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
